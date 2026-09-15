#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

if [ ! -s "$A_PID_FILE" ]; then
  echo "A_STOP=1 reason=no_pid_file"
  exit 0
fi
pid=$(cat "$A_PID_FILE")
if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$A_PID_FILE"
  echo "A_STOP=1 reason=not_running pid=$pid"
  exit 0
fi

kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 80); do
  if [ ! -e "/proc/$pid" ]; then
    rm -f "$A_PID_FILE"
    echo "A_STOP=1 method=term pid=$pid"
    exit 0
  fi
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  if [ "$state" = Z ]; then
    rm -f "$A_PID_FILE"
    echo "A_STOP=1 method=term_zombie pid=$pid"
    exit 0
  fi
  sleep 0.1
done

pgid=$(awk '{print $5}' "/proc/$pid/stat" 2>/dev/null || echo "")
if [ -n "$pgid" ]; then
  kill -TERM "-$pgid" 2>/dev/null || true
  sleep 0.5
fi
if kill -0 "$pid" 2>/dev/null; then
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$A_PID_FILE"
echo "A_STOP=1 method=forced pid=$pid"
