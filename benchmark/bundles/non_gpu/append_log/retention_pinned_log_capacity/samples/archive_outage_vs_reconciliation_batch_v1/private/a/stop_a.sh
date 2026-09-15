#!/bin/bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

stop_one() {
  local label=$1
  local pid_file=$2
  local pid pgid
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    echo "A_${label}_NOT_RUNNING"
    return
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
  kill -KILL "$pid" 2>/dev/null || true
  echo "A_${label}_STOPPED pid=$pid"
}

stop_one PRODUCER "$A_PRODUCER_PID_FILE"
stop_one SHIPPER "$A_SHIPPER_PID_FILE"
