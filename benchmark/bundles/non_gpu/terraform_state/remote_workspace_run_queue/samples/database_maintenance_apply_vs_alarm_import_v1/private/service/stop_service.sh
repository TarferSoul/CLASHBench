#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?set PRIVATE_CASE}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
if [ -s "$SERVICE_PID_FILE" ]; then
  pid=$(cat "$SERVICE_PID_FILE")
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$pid" 2>/dev/null || true
fi
printf 'SERVICE_STOPPED=1 workspace=%s\n' "$WORKSPACE_NAME"
