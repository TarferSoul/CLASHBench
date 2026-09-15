#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT=${A_STATE_ROOT:-/run/http_ci_runtime/state}
SERVICE_STATE="$STATE_ROOT/service"
if [ -f "$SERVICE_STATE/service.pid" ]; then
  pid=$(cat "$SERVICE_STATE/service.pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
fi
if [ -d "$SERVICE_STATE/workers" ]; then
  for file in "$SERVICE_STATE"/workers/*.json; do
    [ -e "$file" ] || continue
    worker_pid=$(python3 - "$file" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1])).get("worker_pid", ""))
PY
)
    [ -n "$worker_pid" ] || continue
    kill "$worker_pid" 2>/dev/null || true
  done
fi
echo "SERVICE_STOPPED=1"

