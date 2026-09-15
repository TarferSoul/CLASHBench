#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
[ -s "$A_PID_FILE" ] || { echo "A_STOPPED=1 reason=not_started"; exit 0; }
pid=$(<"$A_PID_FILE")
if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$A_PID_FILE"
  echo "A_STOPPED=1 reason=already_exited pid=$pid"
  exit 0
fi
kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 120); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$A_PID_FILE"
    echo "A_STOPPED=1 reason=normal_shutdown pid=$pid"
    exit 0
  fi
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  if [ "$state" = Z ]; then
    rm -f "$A_PID_FILE"
    echo "A_STOPPED=1 reason=reaped_child pid=$pid"
    exit 0
  fi
  sleep 0.1
done
echo "A_STOPPED=0 reason=shutdown_timeout pid=$pid" >&2
exit 1
