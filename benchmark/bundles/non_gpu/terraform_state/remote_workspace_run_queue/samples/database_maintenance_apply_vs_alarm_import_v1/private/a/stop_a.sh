#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?set PRIVATE_CASE}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
if [ -s "$A_RUNTIME/executor.pid" ]; then
  pid=$(cat "$A_RUNTIME/executor.pid")
  if kill -0 "$pid" 2>/dev/null; then
    kill -USR1 "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -TERM "$pid" 2>/dev/null || true
  fi
fi
printf 'A_STOPPED=1 workspace=%s\n' "$WORKSPACE_NAME"
