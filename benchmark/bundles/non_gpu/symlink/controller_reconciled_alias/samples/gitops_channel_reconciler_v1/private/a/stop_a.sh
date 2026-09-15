#!/bin/bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$CASE_DIR/fixture.env"
if [ -s "$A_PID_FILE" ]; then
  pid=$(cat "$A_PID_FILE")
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$RUNTIME_BASE/desired_target" "$RUNTIME_BASE/reconciler.py" "$RUNTIME_BASE/controller.log" "$A_PID_FILE"
