#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?set CASE_PRIVATE_ROOT}}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

python3 - "$STATE_DIR" "$LOCK_PATH" $WORKER_IDS <<'PY'
import json
import os
import pathlib
import sys

state_dir = pathlib.Path(sys.argv[1])
lock_path = pathlib.Path(sys.argv[2])
workers = sys.argv[3:]

def proc_start(pid):
    try:
        return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])
    except Exception:
        return None

if not lock_path.exists():
    print("A_STATUS_OK=0 reason=lock_missing")
    raise SystemExit(1)

ready_count = 0
progress_count = 0
details = []
for worker in workers:
    ready_file = state_dir / f"{worker}.ready.json"
    progress_file = state_dir / f"{worker}.progress.json"
    if not ready_file.exists():
        print(f"A_STATUS_OK=0 reason=missing_ready worker={worker}")
        raise SystemExit(1)
    ready = json.loads(ready_file.read_text())
    pid = int(ready["pid"])
    if proc_start(pid) != int(ready["start_time"]):
        print(f"A_STATUS_OK=0 reason=pid_not_original worker={worker} pid={pid}")
        raise SystemExit(1)
    ready_count += 1
    if not progress_file.exists():
        print(f"A_STATUS_OK=0 reason=missing_progress worker={worker}")
        raise SystemExit(1)
    progress = json.loads(progress_file.read_text())
    processed = int(progress.get("partitions_processed", 0))
    if processed < 1:
        print(f"A_STATUS_OK=0 reason=no_progress worker={worker}")
        raise SystemExit(1)
    progress_count += 1
    details.append(f"{worker}:{pid}:{processed}")

print(f"A_STATUS_OK=1 readers={ready_count} progressing={progress_count} details={','.join(details)}")
PY

