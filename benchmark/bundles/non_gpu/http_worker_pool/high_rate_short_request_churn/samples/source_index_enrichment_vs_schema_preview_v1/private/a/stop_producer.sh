#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
mkdir -p "$A_STATE_DIR"
touch "$A_STOP_FILE"
pid=""
if [ -f "$A_PRODUCER_PID_FILE" ]; then
  pid=$(tr -cd '0-9' < "$A_PRODUCER_PID_FILE" || true)
fi
clean=1
if [ -n "$pid" ]; then
  clean=0
  for _ in $(seq 1 120); do
    if [ ! -d "/proc/$pid" ]; then
      clean=1
      break
    fi
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo "?")
    if [ "$state" = Z ]; then
      clean=1
      break
    fi
    sleep 0.1
  done
  if [ "$clean" != 1 ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
fi
echo "PRODUCER_STOPPED clean=$clean pid=${pid:-none}"
exit 0
