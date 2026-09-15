#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=/run/discovery_snapshotter
pid_file="$STATE_DIR/pid"

if [ ! -f "$pid_file" ]; then
  echo "A_STOP=not_running"
  exit 0
fi

pid=$(cat "$pid_file" 2>/dev/null || true)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$pid_file"
  echo "A_STOP=stale_pid"
  exit 0
fi

kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 60); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    echo "A_STOP=1 PID=$pid"
    exit 0
  fi
  sleep 0.1
done

kill -KILL "$pid" 2>/dev/null || true
rm -f "$pid_file"
echo "A_STOP=forced PID=$pid"

