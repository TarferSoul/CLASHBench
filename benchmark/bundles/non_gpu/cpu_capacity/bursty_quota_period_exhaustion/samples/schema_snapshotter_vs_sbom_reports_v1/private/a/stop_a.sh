#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/fixture.env"
if [ -s "$A_PID_FILE" ]; then
  pid=$(cat "$A_PID_FILE")
  case "$pid" in ''|*[!0-9]*) pid= ;; esac
  if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do [ ! -d "/proc/$pid" ] && break; sleep 0.10; done
    [ ! -d "/proc/$pid" ] || kill -KILL -- "-$pid" 2>/dev/null || true
  fi
fi
rm -f "$A_PID_FILE"
echo "A_STOP_OK=1"
