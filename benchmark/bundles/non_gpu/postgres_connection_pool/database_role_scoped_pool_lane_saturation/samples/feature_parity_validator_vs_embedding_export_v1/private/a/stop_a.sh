#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

if [ ! -s "$SERVICE_ROOT/service.pid" ]; then
  echo "A_STOPPED=1 METHOD=not_started"
  exit 0
fi
pid=$(cat "$SERVICE_ROOT/service.pid")
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 120); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "A_STOPPED=1 METHOD=normal PID=$pid"
      exit 0
    fi
    if [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)" = Z ]; then
      echo "A_STOPPED=1 METHOD=normal PID=$pid STATE=zombie"
      exit 0
    fi
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
  echo "A_STOPPED=1 METHOD=forced_after_timeout PID=$pid"
  exit 0
fi
echo "A_STOPPED=1 METHOD=already_exited PID=$pid"
