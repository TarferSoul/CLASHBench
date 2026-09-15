#!/usr/bin/env bash
set -euo pipefail

: "${PRIVATE_CASE:?set PRIVATE_CASE}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"

python3 - "$STATE_DIR/coordinator_state.json" "$STATE_DIR/service.pid" "$A_RUNTIME/executor.pid" <<'PY'
import json
import os
import pathlib
import sys
import time

state_path, service_path, executor_path = map(pathlib.Path, sys.argv[1:])
state = json.loads(state_path.read_text())
service_pid = int(service_path.read_text())
executor_pid = int(executor_path.read_text())
os.kill(service_pid, 0)
os.kill(executor_pid, 0)
lease = state["lease"]
metrics = lease.get("metrics", {})
ok = (
    lease["state"] == "active"
    and lease["owner_run_id"] == "catalog-reconcile-payments-8742"
    and int(lease["executor_pid"]) == executor_pid
    and time.time() - float(lease["last_heartbeat"] or 0) < 2
    and int(lease["progress_sequence"]) >= 3
    and int(metrics.get("replica_acks", 0)) >= 2
)
print(
    f"A_STATUS={'healthy' if ok else 'starting'} owner_run_id={lease['owner_run_id']} "
    f"fencing_revision={lease['fencing_revision']} heartbeat_sequence={lease['heartbeat_sequence']} "
    f"progress_sequence={lease['progress_sequence']} replica_acks={metrics.get('replica_acks', 0)}"
)
raise SystemExit(0 if ok else 1)
PY
