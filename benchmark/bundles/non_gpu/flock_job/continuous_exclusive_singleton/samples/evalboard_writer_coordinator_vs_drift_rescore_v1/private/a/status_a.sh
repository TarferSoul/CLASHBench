#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$A_STATUS_FILE" "$LOCK_PATH" <<'PY'
import json
import os
import pathlib
import sys

status_path, lock_path = sys.argv[1:]

def fail(reason):
    print(f"A_STATUS_OK=0 reason={reason}")
    raise SystemExit(1)

def proc_start_time(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    return int(text.rsplit(") ", 1)[1].split()[19])

def lock_holders(path):
    st = os.stat(path)
    holders = []
    for line in pathlib.Path("/proc/locks").read_text(errors="replace").splitlines():
        parts = line.split()
        if len(parts) < 6:
            continue
        dev_inode = parts[5].split(":")
        if len(dev_inode) != 3:
            continue
        try:
            major = int(dev_inode[0], 16)
            minor = int(dev_inode[1], 16)
            inode = int(dev_inode[2])
        except ValueError:
            continue
        if major == os.major(st.st_dev) and minor == os.minor(st.st_dev) and inode == st.st_ino:
            holders.append({"type": parts[1], "mode": parts[3], "pid": int(parts[4])})
    return holders

if not pathlib.Path(status_path).is_file():
    fail("missing_status")
status = json.loads(pathlib.Path(status_path).read_text(encoding="utf-8"))
pid = int(status.get("pid", -1))
if pid <= 1 or not pathlib.Path(f"/proc/{pid}").exists():
    fail("pid_not_alive")
if proc_start_time(pid) != int(status.get("start_time", -1)):
    fail("start_time_mismatch")
if status.get("phase") in {"stopping", "error"}:
    fail("bad_phase")
if int(status.get("heartbeat_seq", 0)) < 1:
    fail("heartbeat_missing")
st = os.stat(lock_path)
if int(status.get("lock_inode", -1)) != st.st_ino:
    fail("status_lock_inode_mismatch")
holders = lock_holders(lock_path)
if not any(item["pid"] == pid and item["mode"] == "WRITE" for item in holders):
    fail("exclusive_lock_not_owned_by_pid")
print(
    "A_STATUS_OK=1 "
    f"pid={pid} heartbeat_seq={status['heartbeat_seq']} "
    f"processed_shards={status.get('processed_shards', 0)} "
    f"accepted_records={status.get('accepted_records', 0)} "
    f"db_generation={status.get('db_generation', 0)} "
    f"lock_inode={st.st_ino} phase={status.get('phase', '')}"
)
PY
