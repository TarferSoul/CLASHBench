#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"

if [ ! -s "$A_PID_FILE" ]; then
  echo "A_STOPPED=1 worker_pid=missing"
  exit 0
fi

pid=$(cat "$A_PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$A_PID_FILE"
echo "A_STOPPED=1 worker_pid=$pid"
