#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/api_case/private/case}
. "$ROOT/fixture.env"
bash "$ROOT/a/status_a.sh" >/dev/null
bash "$ROOT/platform/status_gateway.sh" >/dev/null
install -d -m 700 "$(dirname "$A_TRUST_FILE")" "$RESULT_ROOT/evidence"

python3 - "$A_ROSTER_FILE" "$A_HEALTH_FILE" "$GATEWAY_IDENTITY_FILE" "$A_TRUST_FILE" "$A_WORKERS" "$GATEWAY_CAPACITY" "$A_HOST" "$A_PORT" "$A_OWNER_PREFIX" "$RESULT_ROOT/evidence/capture_snapshot.json" <<'PY'
import json
import os
import pathlib
import sys
import time
import urllib.request

roster_path, health_path, gateway_path, trust_path, workers, capacity, host, port, owner_prefix, snapshot_path = sys.argv[1:]
workers, capacity = int(workers), int(capacity)
roster = json.loads(pathlib.Path(roster_path).read_text())
health = json.loads(pathlib.Path(health_path).read_text())
gateway = json.loads(pathlib.Path(gateway_path).read_text())
metrics = None
a_active = 0
for _ in range(300):
    health = json.loads(pathlib.Path(health_path).read_text())
    with urllib.request.urlopen(f"http://{host}:{port}/metrics", timeout=1) as response:
        metrics = json.load(response)
    a_active = sum(count for owner, count in metrics["active_by_owner"].items() if owner.startswith(owner_prefix))
    if a_active == capacity:
        break
    time.sleep(0.02)
a_completed = sum(count for owner, count in metrics["completed_by_owner"].items() if owner.startswith(owner_prefix))
snapshot = {"health": health, "roster": roster, "gateway": gateway, "metrics": metrics, "a_active": a_active}
pathlib.Path(snapshot_path).write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n")
os.chmod(snapshot_path, 0o600)
assert health["healthy"] is True and len(roster["workers"]) == workers
assert health["completed_requests"] > 0 and health["output_records"] == health["completed_requests"]
assert a_active == capacity
assert metrics["identity"] == gateway["identity"] and metrics["capacity"] == capacity
trust = {
    "captured_at_ns": time.time_ns(),
    "a_identity": roster["identity"],
    "a_supervisor": roster["supervisor"],
    "a_workers": roster["workers"],
    "a_baseline_completed": health["completed_requests"],
    "a_baseline_output_records": health["output_records"],
    "gateway": gateway,
    "gateway_a_active": a_active,
    "gateway_a_completed": a_completed,
}
tmp = pathlib.Path(f"{trust_path}.{os.getpid()}.tmp")
tmp.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, trust_path)
print(
    f"A_TRUST_CAPTURED=1 supervisor={roster['supervisor']['pid']} workers={workers} "
    f"identity={roster['identity']} completed={health['completed_requests']} "
    f"gateway_identity={gateway['identity']} gateway_a_active={a_active}"
)
PY
