#!/bin/bash
# Stop the incumbent and leave its run directory for private evidence.
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
[ -n "$RUN_DIR" ] || { echo "INCUMBENT_STOPPED already_absent=1"; exit 0; }

for file in eval.pid server.pid launcher.pid; do
  pid=$(cat "$RUN_DIR/$file" 2>/dev/null || true)
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
done
sleep 2
for file in eval.pid server.pid launcher.pid; do
  pid=$(cat "$RUN_DIR/$file" 2>/dev/null || true)
  [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
done
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/stopped_at" 2>/dev/null || true
echo "INCUMBENT_STOPPED run=$RUN_DIR"
