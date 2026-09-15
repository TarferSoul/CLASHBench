#!/usr/bin/env bash
set -u
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
mkdir -p "$A_RUN_DIR"
touch "$A_RUN_DIR/stop" 2>/dev/null || true
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
launcher=$(cat "$A_LAUNCHER_FILE" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
fi
if [ -n "$launcher" ] && [ "$launcher" != "$pid" ] && kill -0 "$launcher" 2>/dev/null; then
  kill "$launcher" 2>/dev/null || true
fi
echo "A_STOPPED service=inference-route-gateway holder_pid=${pid:-unknown}"
