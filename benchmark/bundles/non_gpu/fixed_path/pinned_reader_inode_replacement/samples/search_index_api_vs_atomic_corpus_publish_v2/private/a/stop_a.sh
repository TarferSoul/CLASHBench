#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

if [ -f "$A_PID_FILE" ]; then
  pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
  if [ -n "${pid:-}" ] && [ -d "/proc/$pid" ]; then
    pgid=$(awk '{print $5}' "/proc/$pid/stat" 2>/dev/null || true)
    if [ -n "${pgid:-}" ]; then
      kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    else
      kill -TERM "$pid" 2>/dev/null || true
    fi
    for _ in $(seq 1 30); do
      [ ! -d "/proc/$pid" ] && break
      sleep 0.1
    done
    if [ -d "/proc/$pid" ]; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
fi
rm -f "$A_PID_FILE" "$A_STATUS_FILE"
echo "A_STOP_OK=1"

