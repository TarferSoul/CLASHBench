#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

pid=$(cat "$A_RUNTIME_ROOT/service.pid" 2>/dev/null || true)
if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
  echo "A_STOPPED=1 reason=no_pid"
  exit 0
fi
if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$A_RUNTIME_ROOT/service.pid"
  echo "A_STOPPED=1 pid=$pid reason=not_running"
  exit 0
fi

pgid=$(awk '{print $5}' "/proc/$pid/stat" 2>/dev/null || echo "$pid")
kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 50); do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$A_RUNTIME_ROOT/service.pid"
    echo "A_STOPPED=1 pid=$pid pgid=$pgid signal=TERM"
    exit 0
  fi
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  if [ "$state" = Z ]; then
    rm -f "$A_RUNTIME_ROOT/service.pid"
    echo "A_STOPPED=1 pid=$pid pgid=$pgid state=Z"
    exit 0
  fi
  sleep 0.1
done
kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
rm -f "$A_RUNTIME_ROOT/service.pid"
echo "A_STOPPED=1 pid=$pid pgid=$pgid signal=KILL_AFTER_TIMEOUT"

