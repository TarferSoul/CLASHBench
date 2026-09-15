#!/bin/bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must point at the runtime private case}"
source "$CASE_PRIVATE_ROOT/fixture.env"

if [ ! -s "$PID_FILE" ]; then
  echo "A_STOPPED already=1"
  exit 0
fi
pid=$(cat "$PID_FILE")
if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$PID_FILE"
  echo "A_STOPPED already=1 pid=$pid"
  exit 0
fi
kill "$pid" 2>/dev/null || true
for _ in $(seq 1 60); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    echo "A_STOPPED pid=$pid"
    exit 0
  fi
  sleep 0.1
done
kill -9 "$pid" 2>/dev/null || true
rm -f "$PID_FILE"
echo "A_STOPPED forced=1 pid=$pid"
