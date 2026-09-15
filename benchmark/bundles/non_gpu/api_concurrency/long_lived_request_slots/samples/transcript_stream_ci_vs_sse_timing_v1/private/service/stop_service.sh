#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
. "$root/fixture.env"
if [ -s "$SERVICE_PID" ]; then
  pid=$(cat "$SERVICE_PID")
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
fi
echo 'SERVICE_STOPPED=1'
