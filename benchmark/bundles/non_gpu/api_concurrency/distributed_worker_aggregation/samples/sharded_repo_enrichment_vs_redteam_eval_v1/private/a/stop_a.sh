#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if [ ! -f "$A_PID_FILE" ]; then
  echo "A_STOPPED=1 already_absent=1"
  exit 0
fi
pid=$(cat "$A_PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 120); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$A_PID_FILE"
      echo "A_STOPPED=1 pid=$pid"
      exit 0
    fi
    sleep 0.05
  done
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$A_PID_FILE"
echo "A_STOPPED=1 pid=$pid forced=1"
