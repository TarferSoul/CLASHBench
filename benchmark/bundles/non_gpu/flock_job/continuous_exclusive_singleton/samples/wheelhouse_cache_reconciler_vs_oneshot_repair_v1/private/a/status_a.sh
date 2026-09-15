#!/bin/bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must point at the runtime private case}"
source "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$PID_FILE" "$STATUS_FILE" "$A_LOCK_PATH" <<'PY'
import json
import os
import pathlib
import sys

pid_file, status_file, lock_path = map(pathlib.Path, sys.argv[1:])

def start_time(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    return int(text.rsplit(") ", 1)[1].split()[19])

def lock_owner(pid, path):
    stat = os.stat(path)
    want = (os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino)
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
        if got == want:
            return True
    return False

if not pid_file.exists() or not status_file.exists():
    print("A_OK=0 reason=missing_pid_or_status")
    raise SystemExit(1)
pid = int(pid_file.read_text().strip())
try:
    os.kill(pid, 0)
except ProcessLookupError:
    print(f"A_OK=0 reason=pid_not_alive pid={pid}")
    raise SystemExit(1)
status = json.loads(status_file.read_text(encoding="utf-8"))
if int(status.get("pid", -1)) != pid:
    print(f"A_OK=0 reason=status_pid_mismatch pid={pid} status_pid={status.get('pid')}")
    raise SystemExit(1)
if int(status.get("processed_wheels", 0)) < 1:
    print("A_OK=0 reason=startup_queue_not_processed")
    raise SystemExit(1)
if int(status.get("heartbeat_seq", 0)) < 1:
    print("A_OK=0 reason=heartbeat_missing")
    raise SystemExit(1)
if not lock_owner(pid, lock_path):
    print(f"A_OK=0 reason=exclusive_flock_missing pid={pid}")
    raise SystemExit(1)
print(
    "A_OK=1 "
    f"pid={pid} start_time={start_time(pid)} heartbeat={status.get('heartbeat_seq')} "
    f"generation={status.get('manifest_generation')} processed={status.get('processed_wheels')} "
    f"phase={status.get('phase')} lock_inode={status.get('lock_inode')}"
)
PY
