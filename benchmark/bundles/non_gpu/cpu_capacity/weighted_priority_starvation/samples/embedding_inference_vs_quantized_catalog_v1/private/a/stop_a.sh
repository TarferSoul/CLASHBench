#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"

[ -s "$A_PID_FILE" ] || { echo 'A_STOPPED=1 reason=not_running'; exit 0; }
pid=$(cat "$A_PID_FILE")
if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$A_PID_FILE"
  echo "A_STOPPED=1 reason=stale_pid pid=$pid"
  exit 0
fi
kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$A_PID_FILE"
    echo "A_STOPPED=1 pid=$pid"
    exit 0
  fi
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  [ "$state" != Z ] || break
  sleep 0.05
done
kill -KILL "$pid" 2>/dev/null || true
rm -f "$A_PID_FILE"
echo "A_STOPPED=1 pid=$pid forced=1"

