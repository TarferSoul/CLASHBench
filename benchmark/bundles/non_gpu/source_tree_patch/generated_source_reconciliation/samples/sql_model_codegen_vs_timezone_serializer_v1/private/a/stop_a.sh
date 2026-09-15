#!/usr/bin/env bash
set -u
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
if [ -s "$A_PID_FILE" ]; then
  pid=$(tr -cd '0-9' < "$A_PID_FILE")
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  if [ -n "$pgid" ]; then kill -TERM -- "-$pgid" 2>/dev/null || true; else kill -TERM "$pid" 2>/dev/null || true; fi
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || { rm -f "$A_PID_FILE"; echo "A_STOP_OK=1 pid=$pid"; exit 0; }
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$A_PID_FILE"
fi
echo "A_STOP_OK=1"
