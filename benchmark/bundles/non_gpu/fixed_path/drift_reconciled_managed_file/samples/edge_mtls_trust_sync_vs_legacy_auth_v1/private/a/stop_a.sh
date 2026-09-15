#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    if [ ! -r "/proc/$pid/stat" ] || [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)" = Z ]; then
      break
    fi
    sleep 0.05
  done
  if [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)" != Z ]; then
    kill -9 "$pid" 2>/dev/null || true
  fi
fi
rm -f "$A_PID_FILE" "$A_STATE_FILE"
echo "A_STOPPED pid=${pid:-none}"
