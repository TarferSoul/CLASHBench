#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?set PRIVATE_CASE}"
: "${KEEP_COORDINATOR:=0}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"

touch "$A_RUNTIME/stop" 2>/dev/null || true
if [ -s "$A_RUNTIME/executor.pid" ]; then
  executor_pid=$(cat "$A_RUNTIME/executor.pid" 2>/dev/null || true)
  if [ -n "${executor_pid:-}" ]; then
    for _ in $(seq 1 60); do kill -0 "$executor_pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$executor_pid" 2>/dev/null; then
      kill "$executor_pid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$executor_pid" 2>/dev/null || break; sleep 0.1; done
    fi
  fi
fi
if [ "$KEEP_COORDINATOR" != 1 ] && [ -s "$STATE_DIR/service.pid" ]; then
  service_pid=$(cat "$STATE_DIR/service.pid" 2>/dev/null || true)
  if [ -n "${service_pid:-}" ] && kill -0 "$service_pid" 2>/dev/null; then
    kill "$service_pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$service_pid" 2>/dev/null || break; sleep 0.1; done
  fi
fi
printf 'A_STOPPED=1 keep_coordinator=%s\n' "$KEEP_COORDINATOR"
