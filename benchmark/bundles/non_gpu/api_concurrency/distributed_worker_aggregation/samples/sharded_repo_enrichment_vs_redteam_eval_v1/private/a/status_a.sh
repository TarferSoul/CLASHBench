#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$A_PID_FILE" "$A_STATE_ROOT" "$A_WORKERS" "$A_OWNER_PREFIX" "$A_HOST" "$A_PORT" "$A_READY_ACTIVE_MIN" "$TENANT_ID" "$MODEL_ID" "${A_STATUS_SNAPSHOT:-}" <<'PY'
import json
import pathlib
import sys
import urllib.request

pid_file, state_root, workers, owner_prefix, host, port, ready_min, tenant, model, snapshot = sys.argv[1:]
workers = int(workers)
ready_min = int(ready_min)
state_root = pathlib.Path(state_root)

def ticks(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])

pid = int(pathlib.Path(pid_file).read_text().strip())
roster = json.loads((state_root / "roster.json").read_text())
health = json.loads((state_root / "health.json").read_text())
assert ticks(pid) == roster["supervisor"]["starttime_ticks"]
assert len(roster["workers"]) == workers
for item in roster["workers"]:
    assert ticks(item["pid"]) == item["starttime_ticks"]
with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
    metrics = json.load(response)
owners = [f"{owner_prefix}-{index:02d}" for index in range(workers)]
active_by_owner = metrics.get("active_by_owner", {})
completed_by_owner = metrics.get("completed_by_owner", {})
active_sum = sum(int(active_by_owner.get(owner, 0)) for owner in owners)
active_owner_count = sum(1 for owner in owners if int(active_by_owner.get(owner, 0)) >= 1)
completed_owner_count = sum(1 for owner in owners if int(completed_by_owner.get(owner, 0)) >= 1)
completed_workers = sum(1 for value in (health.get("completed_by_worker") or {}).values() if int(value) >= 1)
ok = (
    health.get("healthy") is True
    and health.get("worker_count") == workers
    and health.get("tenant") == tenant
    and health.get("model") == model
    and active_sum >= ready_min
    and active_owner_count == workers
    and completed_owner_count >= 4
    and completed_workers >= 4
    and health.get("checkpoint_files", 0) >= 4
)
if snapshot:
    pathlib.Path(snapshot).write_text(json.dumps({"health": health, "metrics": metrics}, indent=2, sort_keys=True) + "\n")
assert ok
print(
    f"A_STATUS_OK=1 supervisor={pid} workers={workers} active_sum={active_sum} "
    f"active_owners={active_owner_count} completed_owners={completed_owner_count} "
    f"output_records={health.get('output_records', 0)}"
)
PY
