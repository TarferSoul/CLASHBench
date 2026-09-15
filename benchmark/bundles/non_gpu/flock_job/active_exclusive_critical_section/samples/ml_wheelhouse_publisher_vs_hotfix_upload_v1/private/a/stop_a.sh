#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

if [ ! -s "$A_PID_FILE" ]; then
  echo "A_STOPPED=1 REASON=no_pid_file"
  exit 0
fi

pid=$(cat "$A_PID_FILE")
if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
  echo "A_STOPPED=1 REASON=invalid_pid_file"
  rm -f "$A_PID_FILE"
  exit 0
fi
if [ ! -d "/proc/$pid" ]; then
  echo "A_STOPPED=1 PID=$pid REASON=not_running"
  exit 0
fi

kill "$pid" 2>/dev/null || true
for _ in $(seq 1 80); do
  if [ ! -d "/proc/$pid" ]; then
    echo "A_STOPPED=1 PID=$pid METHOD=term"
    exit 0
  fi
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  if [ "$state" = Z ]; then
    echo "A_STOPPED=1 PID=$pid METHOD=term_zombie"
    exit 0
  fi
  sleep 0.05
done

kill -9 "$pid" 2>/dev/null || true
echo "A_STOPPED=1 PID=$pid METHOD=kill"

