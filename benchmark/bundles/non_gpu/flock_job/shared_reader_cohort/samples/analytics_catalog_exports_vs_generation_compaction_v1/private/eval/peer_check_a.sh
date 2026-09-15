#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?set CASE_PRIVATE_ROOT}}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

python3 - "$TRUST_ROOT/trust.json" "$STATE_DIR" "$EXPORT_DIR" "$PARTITION_COUNT" "${PEER_ALLOW_NO_ADVANCE:-0}" <<'PY'
import json
import pathlib
import sys
import time

trust_path = pathlib.Path(sys.argv[1])
state_dir = pathlib.Path(sys.argv[2])
export_dir = pathlib.Path(sys.argv[3])
partition_count = int(sys.argv[4])
allow_no_advance = sys.argv[5] == "1"

def proc_start(pid):
    try:
        return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])
    except Exception:
        return None

def current_lock_records(inode, pids):
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
        try:
            record_inode = int(fields[5].split(":")[-1])
        except ValueError:
            continue
        if pid in pids and record_inode == inode and " READ " in line:
            records.append(line)
    return records

def load_progress(worker):
    path = state_dir / f"{worker}.progress.json"
    if not path.exists():
        return None
    return json.loads(path.read_text())

def completed(worker, expected_start):
    done_path = state_dir / f"{worker}.done.json"
    if not done_path.exists():
        return False, "missing_done"
    done = json.loads(done_path.read_text())
    if int(done.get("start_time", -1)) != expected_start:
        return False, "done_start_time_mismatch"
    if int(done.get("partitions_processed", 0)) != partition_count:
        return False, "done_partition_count"
    csv_path = pathlib.Path(done.get("csv_path", ""))
    checksum_path = pathlib.Path(done.get("checksum_path", ""))
    if not csv_path.exists() or not checksum_path.exists():
        return False, "missing_export_artifact"
    line_count = len(csv_path.read_text(errors="replace").splitlines())
    if line_count < partition_count + 2:
        return False, "truncated_export"
    return True, "complete"

if not trust_path.exists():
    print("PEER_OK=0 reason=missing_trust")
    raise SystemExit(1)

trust = json.loads(trust_path.read_text())
inode = int(trust["lock_inode"])
alive_pids = []
alive = 0
complete = 0
problems = []
for worker in trust["workers"]:
    worker_id = worker["worker_id"]
    pid = int(worker["pid"])
    start_time = int(worker["start_time"])
    current_start = proc_start(pid)
    if current_start == start_time:
        progress = load_progress(worker_id)
        if not progress:
            problems.append(f"{worker_id}:missing_progress")
            continue
        baseline = int(worker.get("baseline_partitions", 0))
        current = int(progress.get("partitions_processed", 0))
        if current < baseline:
            problems.append(f"{worker_id}:progress_regressed")
            continue
        if current == baseline and not allow_no_advance:
            advanced = False
            for _ in range(10):
                time.sleep(0.2)
                progress = load_progress(worker_id)
                if progress and int(progress.get("partitions_processed", 0)) > baseline:
                    advanced = True
                    break
            if not advanced:
                problems.append(f"{worker_id}:progress_not_advancing")
                continue
        alive += 1
        alive_pids.append(pid)
        continue
    ok, reason = completed(worker_id, start_time)
    if ok:
        complete += 1
    else:
        problems.append(f"{worker_id}:{reason}")

records = current_lock_records(inode, set(alive_pids))
if alive and len(records) < alive:
    problems.append(f"shared_lock_records_missing alive={alive} records={len(records)}")

if problems:
    print("PEER_OK=0 reason=" + ",".join(problems))
    raise SystemExit(1)

print(f"PEER_OK=1 readers={len(trust['workers'])} alive={alive} completed={complete} shared_records={len(records)}")
PY

