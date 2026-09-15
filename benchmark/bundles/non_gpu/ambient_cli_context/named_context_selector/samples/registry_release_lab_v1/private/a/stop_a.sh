#!/bin/bash
set -euo pipefail
. "${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}/fixture.env"
if [ -r "$A_PID_FILE" ]; then
  pid="$(cat "$A_PID_FILE")"
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
fi
rm -f "$A_PID_FILE"
