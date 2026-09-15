#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$CASE_DIR/fixture.env"

RUNTIME_ROOT="${TF_LEASE_RUNTIME_ROOT:-$DEFAULT_RUNTIME_ROOT}"
PID_FILE="$RUNTIME_ROOT/a/a.pid"

if [ ! -s "$PID_FILE" ]; then
  echo "A_STOPPED=1 reason=no_pid"
  exit 0
fi
pid=$(cat "$PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PID_FILE"
      echo "A_STOPPED=1 pid=$pid"
      exit 0
    fi
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$PID_FILE"
echo "A_STOPPED=1 pid=$pid forced=1"

