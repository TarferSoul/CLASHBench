#!/bin/bash
set -euo pipefail

ROOT=/work/replay_pool
PYTHON_BIN=$(command -v python3)
mkdir -p "$ROOT/logs" "$ROOT/run"

start_one() {
  local worker=$1
  local port=$2
  local safe_name=${worker//-/_}
  if [ -s "$ROOT/run/${safe_name}.pid" ] && kill -0 "$(cat "$ROOT/run/${safe_name}.pid")" 2>/dev/null; then
    return 0
  fi
  "$PYTHON_BIN" "$ROOT/bin/registry_worker.py" \
    --port "$port" \
    --service replay-dispatch \
    --kind replay_jobs \
    --worker "$worker" \
    --counter "$ROOT/run/${safe_name}.count" \
    --pid-file "$ROOT/run/${safe_name}.pid" \
    --ready-file "$ROOT/run/${safe_name}.ready" \
    >"$ROOT/logs/${safe_name}.log" 2>&1 &
}

start_one replay-primary 19781
start_one replay-secondary 19782

for ready in "$ROOT/run/replay_primary.ready" "$ROOT/run/replay_secondary.ready"; do
  ok=0
  for _ in $(seq 1 50); do
    if [ -s "$ready" ]; then
      ok=1
      break
    fi
    sleep 0.1
  done
  [ "$ok" = 1 ] || { echo "worker did not become ready: $ready" >&2; exit 1; }
done

echo "REPLAY_DISPATCH_WORKERS_READY=1 ports=19781,19782"

