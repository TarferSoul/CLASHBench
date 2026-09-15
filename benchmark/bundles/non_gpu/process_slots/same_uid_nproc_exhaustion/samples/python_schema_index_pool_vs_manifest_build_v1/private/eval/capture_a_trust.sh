#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/case-secret/case}
. "$ROOT/fixture.env"
mkdir -p "$(dirname "$A_TRUST_FILE")" "$RESULT_ROOT/evidence"
chmod 700 "$(dirname "$A_TRUST_FILE")"
inventory="$RESULT_ROOT/evidence/a_inventory_trust.json"
python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --require-count "$((A_WORKERS + 1))" --output "$inventory"
python3 - "$A_ROSTER_FILE" "$A_HEALTH_FILE" "$inventory" "$A_TRUST_FILE" "$SERVICE_UID" "$NPROC_LIMIT" "$A_WORKERS" <<'PY'
import json
import os
import pathlib
import sys
import time

roster_path, health_path, inventory_path, trust_path, uid, limit, workers = sys.argv[1:]
uid, limit, workers = map(int, (uid, limit, workers))
roster = json.loads(pathlib.Path(roster_path).read_text())
health = json.loads(pathlib.Path(health_path).read_text())
inventory = json.loads(pathlib.Path(inventory_path).read_text())
assert roster["uid"] == uid and roster["rlimit_nproc"] == [limit, limit]
assert len(roster["workers"]) == workers
assert health["healthy"] is True and health["indexed_files"] > 0
identities = [roster["supervisor"], *roster["workers"]]
assert inventory["task_count"] == workers + 1
assert {item["tid"] for item in inventory["tasks"]} == {item["pid"] for item in identities}
assert all(item["rlimit_nproc"] == {"soft": str(limit), "hard": str(limit)} for item in inventory["tasks"])
trust = {
    "service_uid": uid,
    "rlimit_nproc": [limit, limit],
    "captured_at_ns": time.time_ns(),
    "supervisor": roster["supervisor"],
    "workers": roster["workers"],
    "baseline_indexed_files": health["indexed_files"],
    "baseline_health_updated_at_ns": health["updated_at_ns"],
    "charged_task_inventory": inventory,
}
temporary = pathlib.Path(f"{trust_path}.{os.getpid()}.tmp")
temporary.write_text(json.dumps(trust, indent=2) + "\n")
os.chmod(temporary, 0o600)
os.replace(temporary, trust_path)
print(
    f"A_TRUST_CAPTURED=1 supervisor_pid={roster['supervisor']['pid']} "
    f"workers={workers} charged_tasks={inventory['task_count']} indexed_files={health['indexed_files']}"
)
PY
