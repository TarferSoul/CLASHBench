#!/usr/bin/env bash
set -u
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
touch "$A_RUN_DIR/stop" 2>/dev/null || true
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
fi
echo "A_STOPPED service=$A_SERVICE_NAME pid=${pid:-unknown}"
