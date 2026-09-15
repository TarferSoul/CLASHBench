#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/stop_producer.sh" || true
pid=""
if [ -f "$A_SERVICE_PID_FILE" ]; then
  pid=$(tr -cd '0-9' < "$A_SERVICE_PID_FILE" || true)
fi
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    if [ ! -d "/proc/$pid" ]; then
      echo "SERVICE_STOPPED clean=1 pid=$pid"
      exit 0
    fi
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo "?")
    if [ "$state" = Z ]; then
      echo "SERVICE_STOPPED clean=1 pid=$pid zombie=1"
      exit 0
    fi
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
  echo "SERVICE_STOPPED clean=0 pid=$pid"
else
  echo "SERVICE_STOPPED clean=1 pid=${pid:-none} already_absent=1"
fi
