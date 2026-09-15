#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$TRUST_ROOT"
chmod 0700 "$TRUST_ROOT"

python3 - "$A_STATUS_FILE" "$LOCK_PATH" "$TRUST_ROOT/trust.json" <<'PY'
import json
import os
import pathlib
import sys
import time

status_path, lock_path, trust_path = sys.argv[1:]

def fail(reason):
    print(f"TRUST_OK=0 reason={reason}")
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
        fields = parts[5].split(":")
        if len(fields) != 3:
            continue
        try:
            major = int(fields[0], 16)
            minor = int(fields[1], 16)
            inode = int(fields[2])
        except ValueError:
            continue
        if major == os.major(st.st_dev) and minor == os.minor(st.st_dev) and inode == st.st_ino:
            holders.append({"raw": line, "type": parts[1], "mode": parts[3], "pid": int(parts[4])})
    return holders

status = json.loads(pathlib.Path(status_path).read_text(encoding="utf-8"))
pid = int(status["pid"])
if not pathlib.Path(f"/proc/{pid}").exists():
    fail("pid_not_alive")
start_time = proc_start_time(pid)
if start_time != int(status["start_time"]):
    fail("start_time_mismatch")
st = os.stat(lock_path)
holders = lock_holders(lock_path)
if not any(item["pid"] == pid and item["mode"] == "WRITE" for item in holders):
    fail("exclusive_lock_not_found")
trust = {
    "captured_at": time.time(),
    "pid": pid,
    "start_time": start_time,
    "heartbeat_seq": int(status.get("heartbeat_seq", 0)),
    "processed_shards": int(status.get("processed_shards", 0)),
    "accepted_records": int(status.get("accepted_records", 0)),
    "db_generation": int(status.get("db_generation", 0)),
    "phase": status.get("phase", ""),
    "lock_path": lock_path,
    "lock_device_major": os.major(st.st_dev),
    "lock_device_minor": os.minor(st.st_dev),
    "lock_inode": st.st_ino,
    "lock_holders": holders,
    "control_surface": "status_json_only_no_rescore_command_channel"
}
pathlib.Path(trust_path).write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(trust_path, 0o600)
print(
    "TRUST_OK=1 "
    f"pid={pid} start_time={start_time} heartbeat_seq={trust['heartbeat_seq']} "
    f"lock_inode={st.st_ino} accepted_records={trust['accepted_records']}"
)
PY
