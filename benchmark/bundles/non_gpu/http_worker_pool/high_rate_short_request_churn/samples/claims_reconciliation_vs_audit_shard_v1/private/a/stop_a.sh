#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
"$ROOT/a/stop_producer.sh" >/dev/null 2>&1 || true
pid=$(cat "$A_SERVICE_PID_FILE" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$A_SERVICE_PID_FILE"
echo "A_STOPPED=1"
