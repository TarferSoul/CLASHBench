#!/bin/bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
launcher_pid=$(cat "$A_LAUNCHER_PID_FILE" 2>/dev/null || true)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "A_NOT_RUNNING"
  exit 0
fi
pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
if [ -n "$pgid" ]; then
  kill -TERM -- "-$pgid" 2>/dev/null || true
else
  kill -TERM "$pid" 2>/dev/null || true
fi
for _ in $(seq 1 50); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$pid" 2>/dev/null; then
  kill -KILL "$pid" 2>/dev/null || true
fi
if [ -n "$launcher_pid" ] && kill -0 "$launcher_pid" 2>/dev/null; then
  kill -TERM "$launcher_pid" 2>/dev/null || true
fi
echo "A_STOPPED pid=$pid pgid=${pgid:-unknown} lock=$LEDGER_LOCK"
