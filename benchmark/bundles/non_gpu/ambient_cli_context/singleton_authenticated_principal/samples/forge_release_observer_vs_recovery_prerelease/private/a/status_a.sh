#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

pid=$(cat "$A_RUNTIME_ROOT/holder.pid")
service_pid=$(cat "$SERVICE_RUNTIME_DIR/service.pid")
kill -0 "$pid"
kill -0 "$service_pid"
agent_uid=$(id -u agentb)
[ "$(stat -c %u "/proc/$pid")" = "$agent_uid" ]
python3 - "$A_RUNTIME_ROOT/state.json" "$SERVICE_STATE_ROOT/ledger.json" "$A_PRINCIPAL" <<'PY'
import json, sys
worker=json.load(open(sys.argv[1]))
ledger=json.load(open(sys.argv[2]))
principal=sys.argv[3]
observations=[x for x in ledger.get("observations", []) if x.get("principal") == principal]
ok=(worker.get("last_principal") == principal and worker.get("successful_observations", 0) >= 3
    and worker.get("identity_violations", 0) == 0 and worker.get("operation_errors", 0) == 0
    and len(observations) >= 3)
if not ok:
    raise SystemExit(1)
print(f"A_HEALTHY=1 pid={worker['pid']} principal={principal} progress={worker['successful_observations']} last_event={worker['last_event_id']}")
PY
