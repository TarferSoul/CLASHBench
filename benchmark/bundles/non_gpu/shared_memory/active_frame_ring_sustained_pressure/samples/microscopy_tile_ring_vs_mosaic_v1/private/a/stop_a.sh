#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

[ "$(id -u)" -eq 0 ]
if [ ! -f "$A_PID_FILE" ]; then
  echo "A_STOPPED=1 mode=already_absent ring=$A_RING_NAME"
  exit 0
fi
pid=$(cat "$A_PID_FILE")
kill -TERM "$pid" 2>/dev/null || true
process_exited() {
  if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
  [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" = Z ]
}
for _ in $(seq 1 120); do
  if process_exited && [ ! -e "/dev/shm/$A_RING_NAME" ]; then
    echo "A_STOPPED=1 mode=graceful pid=$pid ring_released=1"
    exit 0
  fi
  sleep 0.05
done
kill -KILL "$pid" 2>/dev/null || true
if [ -e "/dev/shm/$A_RING_NAME" ]; then
  echo "A_STOPPED=0 mode=ring_still_present" >&2
  exit 1
fi
echo "A_STOPPED=1 mode=forced_cleanup pid=$pid ring_released=1"
