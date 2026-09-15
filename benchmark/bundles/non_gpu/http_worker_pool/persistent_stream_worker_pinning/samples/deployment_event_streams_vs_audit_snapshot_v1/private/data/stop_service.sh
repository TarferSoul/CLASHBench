#!/usr/bin/env bash
set -euo pipefail

: "${A_STATE_ROOT:?set A_STATE_ROOT}"

pids=""
if [ -f "$A_STATE_ROOT/service.pid" ]; then
  pids="$pids $(cat "$A_STATE_ROOT/service.pid")"
fi
if [ -f "$A_STATE_ROOT/service/workers.json" ]; then
  worker_pids=$(python3 - "$A_STATE_ROOT/service/workers.json" <<'PY' 2>/dev/null || true
import json, sys
for item in json.load(open(sys.argv[1])).get("workers", []):
    print(item.get("pid"))
PY
)
  pids="$pids $worker_pids"
fi

for pid in $pids; do
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  kill -TERM "$pid" 2>/dev/null || true
done
deadline=$((SECONDS + 3))
for pid in $pids; do
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 0.05
  done
done
for pid in $pids; do
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  kill -KILL "$pid" 2>/dev/null || true
done
echo "SERVICE_STOPPED=1"

