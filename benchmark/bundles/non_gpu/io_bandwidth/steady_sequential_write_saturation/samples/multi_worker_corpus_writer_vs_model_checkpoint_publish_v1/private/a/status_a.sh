#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"

python3 - "$A_STATUS_FILE" "$A_WORKER_TABLE" "$A_MIN_READY_BYTES" "$A_WORKERS" <<'PY'
import json
import pathlib
import sys

status_path, table_path, min_ready, expected_workers = sys.argv[1:]
min_ready = int(min_ready)
expected_workers = int(expected_workers)

def alive(pid):
    try:
        return pathlib.Path(f"/proc/{int(pid)}").exists()
    except Exception:
        return False

try:
    status = json.loads(pathlib.Path(status_path).read_text())
    table = json.loads(pathlib.Path(table_path).read_text())
except Exception as exc:
    print(f"A_READY=0 missing_status type={type(exc).__name__}")
    raise SystemExit(1)

workers = status.get("workers", [])
worker_ok = (
    len(workers) == expected_workers
    and all(alive(item.get("pid")) and int(item.get("total_bytes", 0)) > 0 for item in workers)
)
supervisor_ok = alive(status.get("supervisor_pid"))
bytes_ok = int(status.get("total_bytes", 0)) >= min_ready
groups_ok = int(status.get("completed_groups", 0)) >= expected_workers
table_ok = len(table.get("workers", [])) == expected_workers

if supervisor_ok and worker_ok and bytes_ok and groups_ok and table_ok:
    print(
        "A_READY=1 "
        f"supervisor_pid={status.get('supervisor_pid')} "
        f"workers={len(workers)} total_bytes={status.get('total_bytes')} "
        f"completed_groups={status.get('completed_groups')}"
    )
    raise SystemExit(0)

print(
    "A_READY=0 "
    f"supervisor_ok={int(supervisor_ok)} worker_ok={int(worker_ok)} "
    f"bytes_ok={int(bytes_ok)} groups_ok={int(groups_ok)} table_ok={int(table_ok)} "
    f"workers={len(workers)} total_bytes={status.get('total_bytes', 0)} "
    f"completed_groups={status.get('completed_groups', 0)}"
)
raise SystemExit(1)
PY

