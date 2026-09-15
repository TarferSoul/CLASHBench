#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if [ ! -s "$A_PID_FILE" ]; then
  echo "A_STOPPED already=1"
  exit 0
fi
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
pgid=$(awk '{print $5}' "/proc/$pid/stat" 2>/dev/null || true)
if [ -n "$pgid" ]; then
  kill "-$pgid" 2>/dev/null || true
else
  kill "$pid" 2>/dev/null || true
fi
for _ in $(seq 1 50); do
  if [ -z "$pid" ] || [ ! -r "/proc/$pid/stat" ]; then
    rm -f "$A_PID_FILE"
    echo "A_STOPPED pid=${pid:-unknown}"
    exit 0
  fi
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  [ "$state" = Z ] && break
  sleep 0.1
done
kill -9 "$pid" 2>/dev/null || true
rm -f "$A_PID_FILE"
echo "A_STOPPED pid=${pid:-unknown} forced=1"
