#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
[ -s "$MAINTENANCE_PID_FILE" ] || exit 0
pid=$(cat "$MAINTENANCE_PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 80); do
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
    [ -z "$state" ] || [ "$state" = Z ] && exit 0
    sleep 0.1
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
fi
