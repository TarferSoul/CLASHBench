#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/lane_eval/private/case}
. "$ROOT/fixture.env"
if [ -s "$GATEWAY_ROOT/service.pid" ]; then
  pid=$(cat "$GATEWAY_ROOT/service.pid")
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep .05
  done
fi
echo "GATEWAY_STOPPED=1"
