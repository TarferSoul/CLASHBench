#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

stop_pid() {
  local pid_file=$1
  local label=$2
  if [ -s "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file")
    pid_state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
    if [ -n "$pid_state" ] && [ "$pid_state" != Z ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 30); do
        pid_state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
        if [ -z "$pid_state" ] || [ "$pid_state" = Z ] || ! kill -0 "$pid" 2>/dev/null; then
          echo "STOPPED label=$label pid=$pid"
          return 0
        fi
        sleep 0.1
      done
      kill -KILL "$pid" 2>/dev/null || true
      echo "KILLED_AFTER_TERM label=$label pid=$pid"
    fi
  fi
}

mkdir -p "$A_STATE_ROOT"
touch "$A_STOP_FILE" 2>/dev/null || true
stop_pid "$A_CLIENT_PID_FILE" nightly-report-client
stop_pid "$A_SERVICE_PID_FILE" eval-reportd
echo "A_STOP_DONE=1"
