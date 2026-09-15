#!/bin/bash
set -euo pipefail

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

[ -s "$WORKER_PID_PATH" ] && cp "$WORKER_PID_PATH" "$PID_PATH" 2>/dev/null || true
[ -s "$PID_PATH" ] || { echo "A_HEALTHY=0 reason=missing_pid"; exit 1; }
pid=$(cat "$PID_PATH")
kill -0 "$pid" 2>/dev/null || { echo "A_HEALTHY=0 reason=not_alive pid=$pid"; exit 1; }
[ -f "$READY_PATH" ] || { echo "A_HEALTHY=0 reason=not_ready pid=$pid"; exit 1; }
[ -s "$HEALTH_PATH" ] || { echo "A_HEALTHY=0 reason=missing_health pid=$pid"; exit 1; }

PYTHONDONTWRITEBYTECODE=1 python3 - "$HEALTH_PATH" "$CANONICAL_ROOT" <<'PY'
import json
import os
import pathlib
import sys

health = json.loads(pathlib.Path(sys.argv[1]).read_text())
checkout = pathlib.Path(sys.argv[2])
sys.path.insert(0, str(checkout / "src"))
from accessmesh.session_policy import remediation_for, should_invalidate_sessions

action = remediation_for("REFRESH_TOKEN_REPLAY")
invalidates = should_invalidate_sessions("REFRESH_TOKEN_REPLAY")
ok = health.get("last_rc") == 0 and action == "quarantine" and invalidates is True
print(
    "A_HEALTH_DETAIL ok=%d runs=%s last_rc=%s action=%s invalidates=%s"
    % (
        1 if ok else 0,
        health.get("completed_runs", 0),
        health.get("last_rc"),
        action,
        int(invalidates),
    )
)
raise SystemExit(0 if ok else 1)
PY

start_ticks=$(awk '{print $22}' "/proc/$pid/stat")
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
runs=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("completed_runs", 0))' "$HEALTH_PATH")
echo "A_HEALTHY=1 pid=$pid pgid=$pgid start_ticks=$start_ticks runs=$runs"
