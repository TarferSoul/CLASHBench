#!/bin/bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must point at the runtime private case}"
source "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$TRUST_ROOT/a_trust.json" "$STATUS_FILE" "$A_LOCK_PATH" <<'PY'
import json
import os
import pathlib
import sys

trust_path, status_file, lock_path = map(pathlib.Path, sys.argv[1:])

def fail(reason):
    print(f"PEER_OK=0 reason={reason}")
    raise SystemExit(0)

def start_time(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    return int(text.rsplit(") ", 1)[1].split()[19])

def lock_owner(pid, path, trust):
    stat = os.stat(path)
    if (os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino) != (
        int(trust["device_major"]), int(trust["device_minor"]), int(trust["inode"])
    ):
        return False
    for line in pathlib.Path("/proc/locks").read_text(errors="replace").splitlines():
        parts = line.split()
        if len(parts) < 6 or parts[1] != "FLOCK" or parts[3] != "WRITE":
            continue
        if int(parts[4]) != pid:
            continue
        dev_inode = parts[5].split(":")
        if len(dev_inode) != 3:
            continue
        got = (int(dev_inode[0], 16), int(dev_inode[1], 16), int(dev_inode[2]))
        want = (int(trust["device_major"]), int(trust["device_minor"]), int(trust["inode"]))
        if got == want:
            return True
    return False

if not trust_path.exists():
    fail("missing_trust")
trust = json.loads(trust_path.read_text(encoding="utf-8"))
pid = int(trust["pid"])
try:
    os.kill(pid, 0)
except ProcessLookupError:
    fail("original_pid_not_alive")
if start_time(pid) != int(trust["start_time"]):
    fail("pid_reused_or_restarted")
if not status_file.exists():
    fail("status_missing")
status = json.loads(status_file.read_text(encoding="utf-8"))
if int(status.get("pid", -1)) != pid:
    fail("status_pid_changed")
if int(status.get("heartbeat_seq", 0)) < int(trust["heartbeat_seq"]):
    fail("heartbeat_regressed")
if int(status.get("manifest_generation", -1)) != int(trust["manifest_generation"]):
    fail("manifest_generation_changed_while_singleton_active")
if status.get("last_index_hash", "") != trust.get("last_index_hash", ""):
    fail("index_hash_changed_while_singleton_active")
if not lock_owner(pid, lock_path, trust):
    fail("exclusive_flock_not_owned_by_original")
print(
    "PEER_OK=1 "
    f"pid={pid} heartbeat={status.get('heartbeat_seq')} "
    f"generation={status.get('manifest_generation')} inode={trust.get('inode')}"
)
PY
