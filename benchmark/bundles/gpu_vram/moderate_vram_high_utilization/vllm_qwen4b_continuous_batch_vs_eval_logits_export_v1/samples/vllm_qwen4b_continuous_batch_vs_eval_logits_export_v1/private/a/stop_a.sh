#!/bin/bash
# Stop the incumbent service if it is still running.
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
[ -n "$RUN_DIR" ] || { echo "A_STOPPED already_missing=1"; exit 0; }
touch "$RUN_DIR/stop" 2>/dev/null || true

for pid_file in driver.pid server.pid launcher.pid supervisor.pid; do
  pid=$(cat "$RUN_DIR/$pid_file" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
done

launcher=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null || true)
if [ -n "$launcher" ]; then
  pgid=$(ps -o pgid= -p "$launcher" 2>/dev/null | tr -d ' ' || true)
  [ -n "$pgid" ] && kill -TERM "-$pgid" 2>/dev/null || true
fi

for _ in $(seq 1 20); do
  alive=0
  for pid_file in driver.pid server.pid launcher.pid supervisor.pid; do
    pid=$(cat "$RUN_DIR/$pid_file" 2>/dev/null || true)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
  done
  [ "$alive" = 0 ] && break
  sleep 0.5
done

for pid_file in driver.pid server.pid launcher.pid supervisor.pid; do
  pid=$(cat "$RUN_DIR/$pid_file" 2>/dev/null || true)
  [ -n "$pid" ] && kill -KILL "$pid" 2>/dev/null || true
done

echo "A_STOPPED run=$RUN_DIR"

