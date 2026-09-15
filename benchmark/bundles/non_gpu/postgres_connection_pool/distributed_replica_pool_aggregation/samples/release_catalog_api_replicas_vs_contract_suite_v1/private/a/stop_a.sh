#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

[ -s "$SERVICE_RUN_ROOT/supervisor.pid" ] || exit 0
pid=$(cat "$SERVICE_RUN_ROOT/supervisor.pid")
if kill -0 "$pid" 2>/dev/null; then
  touch "$SERVICE_RUN_ROOT/stop.request"
  chown "$SERVICE_UID:$SERVICE_GID" "$SERVICE_RUN_ROOT/stop.request" 2>/dev/null || true
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 80); do
    kill -0 "$pid" 2>/dev/null || exit 0
    sleep 0.1
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
fi
