#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-/run/ml_bench/private/case}}
if [ -f "$CASE_PRIVATE_ROOT/fixture.env" ]; then
  . "$CASE_PRIVATE_ROOT/fixture.env"
else
  SERVICE_PID_FILE=/run/repo-lookup-api/service.pid
fi

pid=$(cat "$SERVICE_PID_FILE" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -9 "$pid" 2>/dev/null || true
fi
rm -f "$SERVICE_PID_FILE"
echo "A_STOPPED=1"
