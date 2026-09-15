#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
if [ -s "$A_PID" ]; then
  pid=$(cat "$A_PID")
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 80); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
    kill -9 "$pid" 2>/dev/null || true
  fi
fi
rm -f "$A_PID"
echo "GATEWAY_SHADOW_STOPPED"
if [ "${STOP_COLLECTOR:-1}" != 0 ]; then bash "$ROOT/data/service_control.sh" stop; fi
