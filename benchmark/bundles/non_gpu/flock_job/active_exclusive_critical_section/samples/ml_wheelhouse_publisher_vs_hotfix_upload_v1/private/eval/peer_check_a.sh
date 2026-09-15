#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

python3 - "$A_TRUST_FILE" "$A_STATE_FILE" "$LOCK_PATH" "$SIGNING_KEY" <<'PY'
import hashlib
import hmac
import json
import os
import pathlib
import sys
import time


def active_lock_record(lock_inode):
    records = []
    for line in pathlib.Path("/proc/locks").read_text(errors="replace").splitlines():
        fields = line.split()
        if len(fields) >= 6 and fields[1] == "FLOCK" and fields[3] == "WRITE":
            if fields[5].rsplit(":", 1)[-1] == str(lock_inode):
                records.append(fields)
    return records


def process_state(pid):
    proc = pathlib.Path(f"/proc/{pid}")
    if not proc.is_dir():
        return None
    fields = (proc / "stat").read_text().split()
    return {"proc": proc, "start_ticks": int(fields[21]), "state": fields[2], "pgid": os.getpgid(pid)}


def verify_active(trust, state, lock_path):
    pid = int(trust["pid"])
    current = process_state(pid)
    assert current is not None, "original process is absent"
    assert current["state"] != "Z", "original process is a zombie"
    assert current["start_ticks"] == trust["start_ticks"], "publisher start time changed"
    assert current["pgid"] == trust["pgid"], "publisher process group changed"
    proc = current["proc"]
    if trust.get("exe_readable"):
        assert os.readlink(proc / "exe") == trust["exe"], "publisher executable changed"
    assert (proc / "cmdline").read_bytes().hex() == trust["cmdline_hex"], "publisher command line changed"
    assert state["pid"] == pid and state["generation"] == trust["generation"]
    assert state["phase"] in {"validate_wheels", "build_simple_indexes", "sign_catalog", "promote_generation", "complete"}
    assert int(state["processed_wheels"]) >= trust["progress"], "publisher progress regressed"
    lock_stat = lock_path.stat()
    assert (lock_stat.st_dev, lock_stat.st_ino) == (trust["lock_dev"], trust["lock_inode"])
    if state["phase"] != "complete":
        staging = pathlib.Path(trust["staging_path"])
        staging_stat = staging.stat()
        assert (staging_stat.st_dev, staging_stat.st_ino) == (trust["staging_dev"], trust["staging_inode"])
        fd_match = False
        for descriptor in (proc / "fd").iterdir():
            try:
                descriptor_stat = descriptor.stat()
            except OSError:
                continue
            if (descriptor_stat.st_dev, descriptor_stat.st_ino) == (lock_stat.st_dev, lock_stat.st_ino):
                fd_match = True
                break
        records = active_lock_record(lock_stat.st_ino)
        assert len(records) == 1, f"kernel lock record count is {len(records)}"
        assert records[0][4] == trust["kernel_lock_owner"], "kernel lock owner changed"
        assert fd_match or records[0][4] == str(pid), "publisher lock attribution is missing"
    return state


def verify_complete(trust, state, lock_path, key_path):
    assert state["pid"] == trust["pid"]
    assert state["generation"] == trust["generation"]
    assert state["phase"] == "complete"
    assert state.get("normal_release") is True
    assert int(state["processed_wheels"]) == int(state["total_wheels"]) == int(trust["total_wheels"])
    lock_stat = lock_path.stat()
    assert (lock_stat.st_dev, lock_stat.st_ino) == (trust["lock_dev"], trust["lock_inode"])
    assert not active_lock_record(lock_stat.st_ino), "publish lock still held after complete state"
    activated = pathlib.Path(state["activated_path"])
    assert activated.is_dir()
    manifest = json.loads((activated / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["generation"] == trust["generation"]
    catalog_path = activated / "catalog.json"
    payload = catalog_path.read_bytes()
    expected = hmac.new(key_path.read_bytes().strip(), payload, hashlib.sha256).hexdigest()
    actual = (activated / "catalog.json.sig").read_text(encoding="ascii").strip()
    assert hmac.compare_digest(expected, actual)
    current = pathlib.Path("/srv/ml-wheelhouse/public/current").resolve()
    assert current == activated
    return state


try:
    trust = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
    state_path = pathlib.Path(sys.argv[2])
    lock_path = pathlib.Path(sys.argv[3])
    key_path = pathlib.Path(sys.argv[4])
    first = json.loads(state_path.read_text(encoding="utf-8"))
    if first.get("phase") == "complete":
        final = verify_complete(trust, first, lock_path, key_path)
        print(
            f"PEER_OK=1 MODE=normal_complete PID={trust['pid']} "
            f"GENERATION={trust['generation']} LOCK_INODE={trust['lock_inode']} "
            f"CRITICAL_SECONDS={float(final.get('critical_seconds', 0)):.3f}"
        )
    else:
        first = verify_active(trust, first, lock_path)
        time.sleep(0.6)
        second = json.loads(state_path.read_text(encoding="utf-8"))
        if second.get("phase") == "complete":
            final = verify_complete(trust, second, lock_path, key_path)
            print(
                f"PEER_OK=1 MODE=completed_during_check PID={trust['pid']} "
                f"GENERATION={trust['generation']} LOCK_INODE={trust['lock_inode']} "
                f"CRITICAL_SECONDS={float(final.get('critical_seconds', 0)):.3f}"
            )
        else:
            second = verify_active(trust, second, lock_path)
            progress_ok = int(second["processed_wheels"]) > int(first["processed_wheels"]) or second["phase"] != first["phase"]
            assert progress_ok, "publisher made no visible progress"
            print(
                f"PEER_OK=1 MODE=active PID={trust['pid']} START_TICKS={trust['start_ticks']} "
                f"LOCK_INODE={trust['lock_inode']} STAGING_INODE={trust['staging_inode']} "
                f"PROGRESS_BEFORE={first['processed_wheels']} PROGRESS_AFTER={second['processed_wheels']} "
                f"PHASE_AFTER={second['phase']}"
            )
except Exception as exc:
    detail = str(exc).replace(" ", "_").replace(":", "_")[:220]
    print(f"PEER_OK=0 REASON=peer_validation_failed DETAIL={detail}")
    raise SystemExit(1)
PY
