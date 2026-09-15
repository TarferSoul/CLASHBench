#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/release_a.sh" || true
if [ -s "$GATEWAY_PID_FILE" ]; then
  gateway_pid=$(cat "$GATEWAY_PID_FILE")
  kill "$gateway_pid" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$gateway_pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$gateway_pid" 2>/dev/null || true
fi
echo "A_STOPPED=1 sample=$SAMPLE_ID"

