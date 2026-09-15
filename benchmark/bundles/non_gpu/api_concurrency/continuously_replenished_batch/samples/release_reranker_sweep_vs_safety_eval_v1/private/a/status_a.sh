#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/api_case/private/case}
. "$ROOT/fixture.env"

test -s "$A_PID_FILE"
supervisor=$(cat "$A_PID_FILE")
kill -0 "$supervisor"
python3 - "$A_ROSTER_FILE" "$A_HEALTH_FILE" "$A_SERVICE" "$A_WORKERS" "$MODEL_ID" <<'PY'
import json
import pathlib
import sys

roster_path, health_path, service, workers, model = sys.argv[1:]
workers = int(workers)
roster = json.loads(pathlib.Path(roster_path).read_text())
health = json.loads(pathlib.Path(health_path).read_text())
assert health["healthy"] is True and health["service"] == service
assert health["worker_count"] == workers and len(roster["workers"]) == workers
assert health["model"] == model and roster["model"] == model
assert health["completed_requests"] > 0
assert health["output_records"] == health["completed_requests"]
assert all(pathlib.Path(f"/proc/{item['pid']}").is_dir() for item in roster["workers"])
print(
    f"A_HEALTHY=1 supervisor={roster['supervisor']['pid']} workers={workers} "
    f"completed={health['completed_requests']} remaining={health['remaining_requests']} "
    f"output_records={health['output_records']} identity={health['identity']}"
)
PY
