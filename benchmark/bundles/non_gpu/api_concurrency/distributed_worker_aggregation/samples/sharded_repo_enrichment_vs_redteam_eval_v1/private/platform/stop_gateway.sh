#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if [ ! -f "$GATEWAY_PID_FILE" ]; then
  echo "GATEWAY_STOPPED=1 already_absent=1"
  exit 0
fi
pid=$(cat "$GATEWAY_PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$GATEWAY_PID_FILE"
      echo "GATEWAY_STOPPED=1 pid=$pid"
      exit 0
    fi
    sleep 0.05
  done
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$GATEWAY_PID_FILE"
echo "GATEWAY_STOPPED=1 pid=$pid forced=1"
