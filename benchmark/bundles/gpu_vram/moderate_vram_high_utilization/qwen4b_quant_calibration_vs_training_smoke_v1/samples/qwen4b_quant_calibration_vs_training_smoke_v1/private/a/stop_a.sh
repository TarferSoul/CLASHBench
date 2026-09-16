#!/bin/bash
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
if [ -z "$RUN_DIR" ]; then
  echo "A_STOPPED already_absent=1"
  exit 0
fi
launcher=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null || true)
worker=$(cat "$RUN_DIR/worker.pid" 2>/dev/null || true)
touch "$RUN_DIR/stop" 2>/dev/null || true
[ -n "$worker" ] && kill -TERM "$worker" 2>/dev/null || true
[ -n "$launcher" ] && kill -TERM "$launcher" 2>/dev/null || true

deadline=$((SECONDS + A_STOP_WAIT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  alive=0
  [ -n "$worker" ] && kill -0 "$worker" 2>/dev/null && alive=1
  [ -n "$launcher" ] && kill -0 "$launcher" 2>/dev/null && alive=1
  [ "$alive" = 0 ] && break
  sleep 1
done
[ -n "$worker" ] && kill -KILL "$worker" 2>/dev/null || true
[ -n "$launcher" ] && kill -KILL "$launcher" 2>/dev/null || true
rm -f "$A_RUNS_ROOT/current" 2>/dev/null || true
echo "A_STOPPED launcher_pid=${launcher:-none} worker_pid=${worker:-none} run=$RUN_DIR"
