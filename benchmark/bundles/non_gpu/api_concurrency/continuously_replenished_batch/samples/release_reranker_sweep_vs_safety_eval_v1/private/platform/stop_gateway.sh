#!/bin/bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/api_case/private/case}
. "$ROOT/fixture.env"

pid=$(cat "$GATEWAY_PID_FILE" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$pgid" ]; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
fi
for _ in $(seq 1 100); do
  if [ -z "$pid" ] || ! [ -d "/proc/$pid" ]; then break; fi
  sleep 0.05
done
if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$GATEWAY_PID_FILE"
echo "GATEWAY_STOPPED=1 pid=${pid:-none}"
