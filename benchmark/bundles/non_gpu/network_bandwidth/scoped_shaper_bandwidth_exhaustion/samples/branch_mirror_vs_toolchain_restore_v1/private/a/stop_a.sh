#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
scope=${STOP_SCOPE:-all}
if [ -s "$A_STATE_ROOT/agent.pid" ]; then
  pid=$(cat "$A_STATE_ROOT/agent.pid")
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep .05; done
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$A_STATE_ROOT/agent.pid"
if [ "$scope" = all ]; then
  if [ -s "$SERVER_STATE_ROOT/server.pid" ]; then kill -TERM "$(cat "$SERVER_STATE_ROOT/server.pid")" 2>/dev/null || true; fi
  if [ -s "$SERVER_STATE_ROOT/launcher.pid" ]; then kill -TERM "$(cat "$SERVER_STATE_ROOT/launcher.pid")" 2>/dev/null || true; fi
  [ "$(cat "$SHAPER_MODE_FILE" 2>/dev/null || printf userspace)" = tc ] && tc qdisc del dev "$LINK_DEVICE" root >/dev/null 2>&1 || true
fi
echo "A_STOPPED=1 scope=$scope"
