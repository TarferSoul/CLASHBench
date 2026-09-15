#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:?}}
. "$ROOT/fixture.env"
if test -s "$PID_FILE"; then
  pid=$(cat "$PID_FILE")
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
fi
rm -f "$PID_FILE"
printf 'A_STOPPED=1 case=%s\n' "$CASE_ID"
