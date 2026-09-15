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
  echo "A_STOPPED=1 PID=$pid REASON=already_exited"
  rm -f "$A_PID_FILE"
  exit 0
fi
pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
if [[ "$pgid" =~ ^[0-9]+$ ]]; then
  kill -TERM "-$pgid" 2>/dev/null || true
else
  kill -TERM "$pid" 2>/dev/null || true
fi
for _ in $(seq 1 80); do
  if [ ! -d "/proc/$pid" ]; then
    rm -f "$A_PID_FILE"
    echo "A_STOPPED=1 PID=$pid"
    exit 0
  fi
  sleep 0.05
done
if [[ "$pgid" =~ ^[0-9]+$ ]]; then
  kill -KILL "-$pgid" 2>/dev/null || true
else
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$A_PID_FILE"
echo "A_STOPPED=1 PID=$pid FORCED=1"

