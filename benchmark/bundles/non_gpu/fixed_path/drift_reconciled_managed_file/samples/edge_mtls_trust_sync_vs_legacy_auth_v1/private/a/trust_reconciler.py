#!/usr/bin/env python3
import ctypes
import hashlib
import hmac
import json
import os
import pathlib
import select
import stat
import struct
import subprocess
import sys
import tempfile
import time


IN_ATTRIB = 0x00000004
IN_CLOSE_WRITE = 0x00000008
IN_MOVED_FROM = 0x00000040
IN_MOVED_TO = 0x00000080
IN_CREATE = 0x00000100
IN_DELETE = 0x00000200
WATCH_MASK = IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_path(path: pathlib.Path) -> str:
    return sha256_bytes(path.read_bytes())


def proc_start_ticks(pid: int) -> str:
    try:
        return pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").split()[21]
    except (OSError, IndexError):
        return ""


def atomic_write(path: pathlib.Path, payload: bytes, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    tmp = pathlib.Path(tmp_name)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as out:
            out.write(payload)
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
        os.chmod(path, mode)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def event_count(payload: bytes) -> int:
    offset = 0
    count = 0
    while offset + 16 <= len(payload):
        _, _, _, name_len = struct.unpack_from("iIII", payload, offset)
        offset += 16 + name_len
        count += 1
    return count


def set_process_name() -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl(15, ctypes.c_char_p(b"edge-trustd"), 0, 0, 0)


def open_inotify(paths: list[pathlib.Path]) -> int:
    libc = ctypes.CDLL(None, use_errno=True)
    fd = libc.inotify_init1(os.O_CLOEXEC)
    if fd < 0:
        raise OSError(ctypes.get_errno(), "inotify_init1 failed")
    for path in paths:
        path.mkdir(parents=True, exist_ok=True)
        wd = libc.inotify_add_watch(fd, os.fsencode(path), WATCH_MASK)
        if wd < 0:
            error = ctypes.get_errno()
            os.close(fd)
            raise OSError(error, f"inotify_add_watch failed for {path}")
    return fd


def load_desired(bundle_path: pathlib.Path, manifest_path: pathlib.Path, key_path: pathlib.Path, target: pathlib.Path) -> dict:
    bundle = bundle_path.read_bytes()
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes.decode("utf-8"))
    signature = manifest.get("signature_hmac_sha256", "")
    unsigned = {key: value for key, value in manifest.items() if key != "signature_hmac_sha256"}
    message = json.dumps(unsigned, sort_keys=True, separators=(",", ":")).encode("utf-8")
    expected_sig = hmac.new(key_path.read_bytes(), message, hashlib.sha256).hexdigest()
    expected_sha = sha256_bytes(bundle)
    desired_mode = str(manifest.get("mode", ""))
    verified = (
        hmac.compare_digest(signature, expected_sig)
        and manifest.get("bundle_sha256") == expected_sha
        and manifest.get("path") == str(target)
        and desired_mode in {"0444", "0644"}
        and manifest.get("owner") == "agentb:agentb"
    )
    return {
        "bundle": bundle,
        "bundle_sha256": expected_sha,
        "manifest_sha256": sha256_bytes(manifest_bytes),
        "mode": desired_mode,
        "source_verified": verified,
    }


def target_state(path: pathlib.Path) -> dict:
    try:
        info = path.lstat()
        is_regular = stat.S_ISREG(info.st_mode) and not path.is_symlink()
        digest = sha256_path(path) if is_regular else ""
        return {
            "exists": True,
            "regular": is_regular,
            "sha256": digest,
            "mode": f"{stat.S_IMODE(info.st_mode):04o}",
            "uid": info.st_uid,
            "gid": info.st_gid,
            "inode": f"{info.st_dev}:{info.st_ino}",
        }
    except OSError:
        return {
            "exists": False,
            "regular": False,
            "sha256": "",
            "mode": "",
            "uid": None,
            "gid": None,
            "inode": "",
        }


def target_matches(path: pathlib.Path, desired: dict) -> bool:
    current = target_state(path)
    return (
        desired["source_verified"]
        and current["regular"]
        and current["sha256"] == desired["bundle_sha256"]
        and current["mode"] == desired["mode"]
        and current["uid"] == os.getuid()
        and current["gid"] == os.getgid()
    )


def consumer_ok(target: pathlib.Path, prod_leaf: pathlib.Path) -> bool:
    try:
        proc = subprocess.run(
            ["openssl", "verify", "-CAfile", str(target), str(prod_leaf)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=3,
        )
        return proc.returncode == 0
    except Exception:
        return False


def write_state(path: pathlib.Path, state: dict) -> None:
    payload = json.dumps(state, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    atomic_write(path, payload, 0o600)


def main() -> int:
    if len(sys.argv) != 8:
        print("usage: trust_reconciler.py TARGET BUNDLE MANIFEST KEY STATE PROD_LEAF EVENT_WAIT", file=sys.stderr)
        return 2
    target = pathlib.Path(sys.argv[1])
    bundle_path = pathlib.Path(sys.argv[2])
    manifest_path = pathlib.Path(sys.argv[3])
    key_path = pathlib.Path(sys.argv[4])
    state_path = pathlib.Path(sys.argv[5])
    prod_leaf = pathlib.Path(sys.argv[6])
    event_wait = float(sys.argv[7])
    target.parent.mkdir(parents=True, exist_ok=True)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    set_process_name()
    watch_fd = open_inotify([target.parent, bundle_path.parent])
    pid = os.getpid()
    start_ticks = proc_start_ticks(pid)
    reconcile_count = 0
    observed_events = 0

    while True:
        desired = {
            "bundle": b"",
            "bundle_sha256": "",
            "manifest_sha256": "",
            "source_verified": False,
        }
        try:
            desired = load_desired(bundle_path, manifest_path, key_path, target)
            if not target_matches(target, desired):
                atomic_write(target, desired["bundle"], int(desired["mode"], 8))
                reconcile_count += 1
        except Exception as exc:
            desired["source_error"] = f"{type(exc).__name__}: {exc}"
        current = target_state(target)
        state = {
            "pid": pid,
            "pgid": os.getpgrp(),
            "start_ticks": start_ticks,
            "desired_sha256": desired.get("bundle_sha256", ""),
            "manifest_sha256": desired.get("manifest_sha256", ""),
            "desired_mode": desired.get("mode", ""),
            "source_verified": bool(desired.get("source_verified")),
            "target": current,
            "reconcile_count": reconcile_count,
            "inotify_event_count": observed_events,
            "heartbeat_epoch": time.time(),
            "consumer_ok": consumer_ok(target, prod_leaf),
        }
        if "source_error" in desired:
            state["source_error"] = desired["source_error"]
        write_state(state_path, state)
        ready, _, _ = select.select([watch_fd], [], [], event_wait)
        if ready:
            observed_events += event_count(os.read(watch_fd, 65536))


if __name__ == "__main__":
    raise SystemExit(main())
