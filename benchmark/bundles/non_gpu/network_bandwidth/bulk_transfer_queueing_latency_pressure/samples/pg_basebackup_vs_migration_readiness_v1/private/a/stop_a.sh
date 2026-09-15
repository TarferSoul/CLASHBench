#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

scope=${STOP_SCOPE:-all}
touch "$A_STATE_ROOT/stop_publisher" 2>/dev/null || true

stop_pid_file() {
  local name=$1
  local pid_file="$A_STATE_ROOT/$name.pid"
  if [ -s "$pid_file" ]; then
    pid=$(cat "$pid_file")
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$pid_file"
  fi
}

stop_pid_file publisher
if [ "$scope" = all ]; then
  stop_pid_file relay
  stop_pid_file backend
fi

echo "A_STOP_OK=1 scope=$scope"
