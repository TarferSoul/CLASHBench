#!/usr/bin/env bash
set -u
ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"
pid=$(cat "$SEGMENT_RUN/a.pid" 2>/dev/null || true)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then echo 'A_NOT_RUNNING'; exit 0; fi
pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
if [ -n "$pgid" ]; then kill -TERM -- "-$pgid" 2>/dev/null || true; else kill -TERM "$pid" 2>/dev/null || true; fi
for _ in $(seq 1 80); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.05
done
kill -KILL "$pid" 2>/dev/null || true
echo "A_STOPPED pid=$pid"
