#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

[ -s "$SERVICE_ROOT/export.pid" ] || exit 0
pid=$(cat "$SERVICE_ROOT/export.pid")
if kill -0 "$pid" 2>/dev/null; then
  touch "$SERVICE_ROOT/stop.request"
  chown "$AGENT_UID:$AGENT_GID" "$SERVICE_ROOT/stop.request"
  for _ in $(seq 1 120); do
    kill -0 "$pid" 2>/dev/null || exit 0
    sleep 0.1
  done
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || exit 0
    sleep 0.1
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
fi
