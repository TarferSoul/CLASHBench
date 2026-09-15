#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"

process_alive() {
  local pid=$1 state
  [ -n "$pid" ] && [ -r "/proc/$pid/stat" ] || return 1
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  [ "$state" != Z ]
}

wait_stopped() {
  local pid=$1 state
  for _ in $(seq 1 80); do
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
    if [ ! -r "/proc/$pid/stat" ] || [ "$state" = Z ]; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

stop_pid_group() {
  local pid=$1
  if process_alive "$pid"; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    wait_stopped "$pid" || kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
}

nginx_pid=$(cat "$NGINX_PID_FILE" 2>/dev/null || true)
if process_alive "$nginx_pid"; then
  kill -QUIT "$nginx_pid" 2>/dev/null || true
  wait_stopped "$nginx_pid" || kill -KILL "$nginx_pid" 2>/dev/null || true
fi

for pid_file in "$A_PROBE_PID_FILE" "$A_BACKEND_PID_FILE" "$B_BACKEND_PID_FILE"; do
  pid=$(cat "$pid_file" 2>/dev/null || true)
  stop_pid_group "$pid"
done
echo "A_STOPPED nginx_pid=${nginx_pid:-missing}"
