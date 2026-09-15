#!/usr/bin/env python3
import hashlib
import hmac
import json
import os
import pathlib
import pwd
import grp
import signal
import stat
import sys
import time


running = True


def handle_signal(signum, frame):
    global running
    running = False


def sha256_path(path):
    h = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
      for chunk in iter(lambda: handle.read(1024 * 1024), b""):
          h.update(chunk)
    return h.hexdigest()


def read_manifest(bundle_path, manifest_path, key_path):
    bundle_path = pathlib.Path(bundle_path)
    manifest_path = pathlib.Path(manifest_path)
    key = pathlib.Path(key_path).read_bytes()
    manifest = json.loads(manifest_path.read_text())
    supplied = manifest.pop("hmac_sha256", "")
    msg = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
    expected_sig = hmac.new(key, msg, hashlib.sha256).hexdigest()
    source_digest = sha256_path(bundle_path)
    ok = (
        hmac.compare_digest(supplied, expected_sig)
        and manifest.get("bundle_sha256") == source_digest
        and manifest.get("target_mode") == "0440"
        and manifest.get("target_owner") == "agentb"
        and manifest.get("target_group") == "secscan"
    )
    manifest["hmac_sha256"] = supplied
    return ok, manifest, source_digest, sha256_path(manifest_path)


def target_state(path):
    path = pathlib.Path(path)
    try:
        info = path.lstat()
        payload = path.read_bytes() if stat.S_ISREG(info.st_mode) and not path.is_symlink() else b""
        return {
            "exists": True,
            "regular": stat.S_ISREG(info.st_mode) and not path.is_symlink(),
            "mode": f"{stat.S_IMODE(info.st_mode):04o}",
            "uid": info.st_uid,
            "gid": info.st_gid,
            "sha256": hashlib.sha256(payload).hexdigest() if payload else "",
            "size": info.st_size,
            "inode": info.st_ino,
            "device": info.st_dev,
        }
    except FileNotFoundError:
        return {"exists": False, "regular": False, "mode": "", "uid": -1, "gid": -1, "sha256": "", "size": 0, "inode": 0, "device": 0}


def restore_target(target, bundle_path, uid, gid):
    target = pathlib.Path(target)
    tmp = target.with_name(f".policy-agent-{os.getpid()}.tmp")
    data = pathlib.Path(bundle_path).read_bytes()
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data)
        os.fchown(fd, uid, gid)
        os.fchmod(fd, 0o440)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(tmp, target)
    try:
        dfd = os.open(str(target.parent), os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


def load_bundle(path):
    data = json.loads(pathlib.Path(path).read_text())
    rules = data.get("rules", [])
    return data, rules


def scan_canary(policy_path, canary_dir):
    bundle, rules = load_bundle(policy_path)
    findings = []
    for fixture in sorted(pathlib.Path(canary_dir).glob("*")):
        if not fixture.is_file():
            continue
        text = fixture.read_text(errors="replace")
        for rule in rules:
            pattern = str(rule.get("pattern", ""))
            if pattern and pattern in text:
                findings.append({"rule_id": rule.get("id", ""), "file": str(fixture)})
    found = {item["rule_id"] for item in findings}
    ok = (
        bundle.get("schema_version") == "bundle-v3"
        and len(rules) == 18
        and "SEC_BASE_005" in found
        and "SEC_BASE_012" in found
    )
    return ok, len(rules), findings


def write_state(path, state):
    path = pathlib.Path(path)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def main():
    if len(sys.argv) != 8:
        raise SystemExit("usage: policy_agent.py TARGET BUNDLE MANIFEST KEY STATE CANARY_DIR INTERVAL")
    target, bundle, manifest, key, state_path, canary_dir, interval_s = sys.argv[1:]
    interval = float(interval_s)
    uid = pwd.getpwnam("agentb").pw_uid
    gid = grp.getgrnam("secscan").gr_gid
    repair_count = 0
    audit_count = 0
    last_repair_reason = "initial"
    started_at = time.time()
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    while running:
        audit_count += 1
        source_ok = False
        desired_digest = ""
        manifest_digest = ""
        canary_ok = False
        rule_count = 0
        canary_findings = []
        reason = ""
        try:
            source_ok, desired, desired_digest, manifest_digest = read_manifest(bundle, manifest, key)
            state_before = target_state(target)
            desired_mode = desired.get("target_mode")
            if not source_ok:
                reason = "source_signature_invalid"
            elif (
                not state_before["regular"]
                or state_before["sha256"] != desired_digest
                or state_before["mode"] != desired_mode
                or state_before["uid"] != uid
                or state_before["gid"] != gid
            ):
                restore_target(target, bundle, uid, gid)
                repair_count += 1
                reason = "restored_target"
                last_repair_reason = reason
            canary_ok, rule_count, canary_findings = scan_canary(target, canary_dir)
        except Exception as exc:
            reason = f"error:{type(exc).__name__}"
        current = target_state(target)
        write_state(
            state_path,
            {
                "pid": os.getpid(),
                "pgid": os.getpgid(0),
                "started_at": started_at,
                "heartbeat": time.time(),
                "audit_count": audit_count,
                "repair_count": repair_count,
                "last_repair_reason": last_repair_reason,
                "current_reason": reason,
                "source_verified": source_ok,
                "desired_digest": desired_digest,
                "manifest_digest": manifest_digest,
                "target": current,
                "baseline_rule_count": rule_count,
                "canary_ok": canary_ok,
                "canary_findings": canary_findings[-10:],
            },
        )
        for _ in range(max(1, int(interval * 10))):
            if not running:
                break
            time.sleep(0.1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
