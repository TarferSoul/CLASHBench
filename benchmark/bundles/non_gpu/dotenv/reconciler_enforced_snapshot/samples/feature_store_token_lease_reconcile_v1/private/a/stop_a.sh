#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

stop_pid_file() {
  local pid_file=$1
  local label=$2
  if [ ! -s "$pid_file" ]; then
    echo "STOP_SKIP label=$label reason=no_pid_file"
    return 0
  fi
  local pid
  pid=$(cat "$pid_file")
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "STOP_SKIP label=$label pid=$pid reason=not_running"
    rm -f "$pid_file"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "STOP_OK label=$label pid=$pid"
      rm -f "$pid_file"
      return 0
    fi
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
  rm -f "$pid_file"
  echo "STOP_KILL label=$label pid=$pid"
}

stop_pid_file "$A_PID_FILE" reconciler
stop_pid_file "$API_PID_FILE" api
