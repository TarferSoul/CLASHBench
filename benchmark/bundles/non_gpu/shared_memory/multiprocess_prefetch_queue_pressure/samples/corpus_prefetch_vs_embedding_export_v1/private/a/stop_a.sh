#!/usr/bin/env bash
set -euo pipefail

ROOT=${PREFETCH_ROOT:?PREFETCH_ROOT must point to the private fixture}
. "$ROOT/fixture.env"
STATE_DIR=${A_STATE_DIR:-/var/lib/corpus-prefetch}
PID_FILE="$STATE_DIR/supervisor.pid"

if [ ! -s "$PID_FILE" ]; then
  echo "A_STOP=not_running"
  exit 0
fi
pid=$(cat "$PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
fi
rm -f "$PID_FILE"
echo "A_STOP=stopped pid=$pid"

