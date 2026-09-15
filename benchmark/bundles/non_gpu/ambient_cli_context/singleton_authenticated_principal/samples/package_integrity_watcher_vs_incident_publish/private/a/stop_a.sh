#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"
if [ -s "$A_RUNTIME_ROOT/holder.pid" ]; then
  pid=$(cat "$A_RUNTIME_ROOT/holder.pid")
  if kill -0 "$pid" 2>/dev/null; then
    runuser -u agentb -- kill -TERM "$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL "$pid" 2>/dev/null || true
  fi
fi
if [ -s "$SERVICE_RUNTIME_DIR/service.pid" ]; then
  service_pid=$(cat "$SERVICE_RUNTIME_DIR/service.pid")
  kill -TERM "$service_pid" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$service_pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$service_pid" 2>/dev/null || true
fi
printf 'A_STOPPED=1\n'
