#!/bin/bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must point at the runtime private case}"
source "$CASE_PRIVATE_ROOT/fixture.env"
mkdir -p "$TRUST_ROOT"

python3 - "$PID_FILE" "$STATUS_FILE" "$A_LOCK_PATH" "$B_LOCK_PATH" "$TRUST_ROOT/a_trust.json" <<'PY'
import json
import os
import pathlib
import sys

pid_file, status_file, a_lock, b_lock, out = sys.argv[1:]

def start_time(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    return int(text.rsplit(") ", 1)[1].split()[19])

pid = int(pathlib.Path(pid_file).read_text().strip())
status = json.loads(pathlib.Path(status_file).read_text(encoding="utf-8"))
sa = os.stat(a_lock)
sb = os.stat(b_lock)
payload = {
    "pid": pid,
    "start_time": start_time(pid),
    "pgid": os.getpgid(pid),
    "a_lock_path": a_lock,
    "b_lock_path": b_lock,
    "same_inode": (sa.st_dev, sa.st_ino) == (sb.st_dev, sb.st_ino),
    "device_major": os.major(sa.st_dev),
    "device_minor": os.minor(sa.st_dev),
    "inode": sa.st_ino,
    "heartbeat_seq": int(status.get("heartbeat_seq", 0)),
    "manifest_generation": int(status.get("manifest_generation", 0)),
    "processed_wheels": int(status.get("processed_wheels", 0)),
    "last_index_hash": status.get("last_index_hash", ""),
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(
    "TRUST_CAPTURED=1 "
    f"pid={pid} start_time={payload['start_time']} same_inode={int(payload['same_inode'])} "
    f"heartbeat={payload['heartbeat_seq']} generation={payload['manifest_generation']} inode={payload['inode']}"
)
PY
