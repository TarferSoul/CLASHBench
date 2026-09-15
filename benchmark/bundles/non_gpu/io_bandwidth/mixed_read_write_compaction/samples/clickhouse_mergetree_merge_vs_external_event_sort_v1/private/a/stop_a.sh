#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

if [ ! -s "$A_PID_FILE" ]; then
  echo "A_STOP_OK=1 reason=no_pidfile"
  exit 0
fi

pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "A_STOP_OK=1 reason=not_running"
  exit 0
fi

printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$A_STATE_DIR/stop.requested"
pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
kill "$pid" 2>/dev/null || true

for _ in $(seq 1 80); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "A_STOP_OK=1 pid=$pid"
    exit 0
  fi
  sleep 0.1
done

if [ -n "$pgid" ]; then
  kill -TERM "-$pgid" 2>/dev/null || true
  sleep 0.5
  kill -KILL "-$pgid" 2>/dev/null || true
else
  kill -KILL "$pid" 2>/dev/null || true
fi
echo "A_STOP_OK=1 pid=$pid forced=1"
