#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?set CASE_PRIVATE_ROOT}}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"

python3 - "$STATE_DIR" "$LOCK_PATH" "$TRUST_ROOT/trust.json" $WORKER_IDS <<'PY'
import json
import os
import pathlib
import sys
import time

state_dir = pathlib.Path(sys.argv[1])
lock_path = pathlib.Path(sys.argv[2])
trust_path = pathlib.Path(sys.argv[3])
workers = sys.argv[4:]

def proc_start(pid):
    try:
        return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])
    except Exception:
        return None

def lock_records(inode, pids):
    records = []
    try:
        lines = pathlib.Path("/proc/locks").read_text(errors="replace").splitlines()
    except Exception:
        return records
    for line in lines:
        fields = line.split()
        if len(fields) < 6:
            continue
        try:
            pid = int(fields[4])
        except ValueError:
            continue
        dev_inode = fields[5].split(":")
        try:
            record_inode = int(dev_inode[-1])
        except ValueError:
            continue
        if pid in pids and record_inode == inode:
            records.append(line)
    return records

if not lock_path.exists():
    print("TRUST_CAPTURE_OK=0 reason=lock_missing")
    raise SystemExit(1)
lock_stat = lock_path.stat()
captured = []
pids = []
for worker in workers:
    ready_file = state_dir / f"{worker}.ready.json"
    progress_file = state_dir / f"{worker}.progress.json"
    if not ready_file.exists() or not progress_file.exists():
        print(f"TRUST_CAPTURE_OK=0 reason=missing_state worker={worker}")
        raise SystemExit(1)
    ready = json.loads(ready_file.read_text())
    progress = json.loads(progress_file.read_text())
    pid = int(ready["pid"])
    if proc_start(pid) != int(ready["start_time"]):
        print(f"TRUST_CAPTURE_OK=0 reason=pid_not_original worker={worker}")
        raise SystemExit(1)
    if int(ready["lock_inode"]) != lock_stat.st_ino:
        print(f"TRUST_CAPTURE_OK=0 reason=inode_mismatch worker={worker}")
        raise SystemExit(1)
    if int(progress.get("partitions_processed", 0)) < 1:
        print(f"TRUST_CAPTURE_OK=0 reason=no_progress worker={worker}")
        raise SystemExit(1)
    pids.append(pid)
    captured.append(
        {
            "worker_id": worker,
            "pid": pid,
            "start_time": int(ready["start_time"]),
            "role": ready["role"],
            "baseline_partitions": int(progress.get("partitions_processed", 0)),
            "baseline_rows": int(progress.get("rows_written", 0)),
            "progress_file": str(progress_file),
            "ready_file": str(ready_file),
        }
    )
records = lock_records(lock_stat.st_ino, set(pids))
read_records = [line for line in records if " READ " in line]
if len(read_records) < len(workers):
    print(f"TRUST_CAPTURE_OK=0 reason=missing_shared_lock_records expected={len(workers)} got={len(read_records)}")
    raise SystemExit(1)
payload = {
    "captured_at": time.time(),
    "lock_path": str(lock_path),
    "lock_inode": lock_stat.st_ino,
    "lock_device": lock_stat.st_dev,
    "workers": captured,
    "lock_records": read_records,
}
trust_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(f"TRUST_CAPTURE_OK=1 readers={len(captured)} inode={lock_stat.st_ino} records={len(read_records)} trust={trust_path}")
PY

