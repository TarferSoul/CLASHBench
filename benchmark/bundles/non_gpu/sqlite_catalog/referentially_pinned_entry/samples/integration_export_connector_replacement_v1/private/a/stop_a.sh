#!/bin/bash
set -u

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

touch "$A_RUN_DIR/stop" 2>/dev/null || true
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  for _ in $(seq 1 20); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "A_STOPPED service=$A_SERVICE_NAME pid=$pid mode=graceful"
      exit 0
    fi
    python3 - <<'PY'
import time
time.sleep(0.1)
PY
  done
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$pgid" ]; then
    kill -- "-$pgid" 2>/dev/null || true
  else
    kill "$pid" 2>/dev/null || true
  fi
fi
echo "A_STOPPED service=$A_SERVICE_NAME pid=${pid:-unknown} mode=signal"
