#!/bin/bash
set -euo pipefail

: "${PRIVATE_CASE:?}"
. "$PRIVATE_CASE/fixture.env"

pid_file="$A_RUNTIME_ROOT/pid"
if [ -s "$pid_file" ]; then
  pid=$(cat "$pid_file")
  touch "$A_RUNTIME_ROOT/stop" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  kill -9 "$pid" 2>/dev/null || true
fi
if [ -s "$A_RUNTIME_ROOT/launcher.pid" ]; then
  launcher_pid=$(cat "$A_RUNTIME_ROOT/launcher.pid")
  kill "$launcher_pid" 2>/dev/null || true
fi
rm -rf "$A_RUNTIME_ROOT"
echo "A_STOPPED=1"
