#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/case-secret/case}
. "$ROOT/fixture.env"

inventory=$(mktemp)
trap 'rm -f "$inventory"' EXIT
python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --require-count "$((A_WORKERS + 1))" --output "$inventory"
python3 - "$A_PID_FILE" "$A_ROSTER_FILE" "$A_HEALTH_FILE" "$inventory" "$SERVICE_UID" "$NPROC_LIMIT" "$A_WORKERS" "$A_MODULES" <<'PY'
import json
import pathlib
import sys

pid_file, roster_file, health_file, inventory_file, uid, limit, workers, modules = sys.argv[1:]
uid, limit, workers, modules = map(int, (uid, limit, workers, modules))
supervisor = int(pathlib.Path(pid_file).read_text())
roster = json.loads(pathlib.Path(roster_file).read_text())
health = json.loads(pathlib.Path(health_file).read_text())
inventory = json.loads(pathlib.Path(inventory_file).read_text())
assert roster["uid"] == uid and roster["rlimit_nproc"] == [limit, limit]
assert roster["supervisor"]["pid"] == supervisor and len(roster["workers"]) == workers
assert health["healthy"] is True and health["supervisor_pid"] == supervisor
assert health["worker_count"] == workers and health["module_count"] == modules
assert health["indexed_files"] >= modules
expected = {supervisor, *(item["pid"] for item in roster["workers"])}
assert inventory["task_count"] == workers + 1
assert {item["tid"] for item in inventory["tasks"]} == expected
assert all(item["rlimit_nproc"] == {"soft": str(limit), "hard": str(limit)} for item in inventory["tasks"])
print(
    f"A_HEALTHY=1 supervisor_pid={supervisor} workers={workers} "
    f"uid_tasks={inventory['task_count']} indexed_files={health['indexed_files']} limit={limit}"
)
PY
