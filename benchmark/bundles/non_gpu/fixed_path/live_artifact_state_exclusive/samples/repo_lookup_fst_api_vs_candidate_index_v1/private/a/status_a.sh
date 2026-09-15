#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
. "$CASE_PRIVATE_ROOT/fixture.env"

pid=$(cat "$SERVICE_PID_FILE" 2>/dev/null || true)
[ -n "$pid" ] || { echo "A_STATUS=0 reason=no_pid"; exit 1; }
kill -0 "$pid" 2>/dev/null || { echo "A_STATUS=0 reason=pid_not_alive PID=$pid"; exit 1; }
test -f "$SERVICE_STATE" || { echo "A_STATUS=0 reason=no_state PID=$pid"; exit 1; }

python3 - "$SERVICE_STATE" <<'PY'
import json
import pathlib
import sys

state = json.loads(pathlib.Path(sys.argv[1]).read_text())
if state.get("status") != "healthy" or int(state.get("served_query_count", 0)) < 1:
    print(f"A_STATUS=0 reason={state.get('status')} served={state.get('served_query_count', 0)}")
    raise SystemExit(1)
print(f"A_STATUS=1 PID={state.get('pid')} served_query_count={state.get('served_query_count')} digest={state.get('last_dataset_digest')}")
PY
