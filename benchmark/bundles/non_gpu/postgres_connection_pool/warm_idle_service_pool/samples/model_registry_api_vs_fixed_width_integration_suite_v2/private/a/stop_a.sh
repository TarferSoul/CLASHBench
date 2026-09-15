#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

if [ ! -s "$SERVICE_ROOT/service.pid" ]; then
  echo "A_STOPPED=1 REASON=no_pid_file"
  exit 0
fi
pid=$(cat "$SERVICE_ROOT/service.pid")
if ! kill -0 "$pid" 2>/dev/null; then
  echo "A_STOPPED=1 PID=$pid REASON=already_gone"
  exit 0
fi

touch "$SERVICE_ROOT/stop.request"
chown "$SERVICE_UID:$SERVICE_GID" "$SERVICE_ROOT/stop.request" 2>/dev/null || true
for _ in $(seq 1 80); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "A_STOPPED=1 PID=$pid METHOD=stop_file"
    exit 0
  fi
  sleep 0.1
done
kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 40); do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "A_STOPPED=1 PID=$pid METHOD=term"
    exit 0
  fi
  sleep 0.1
done
kill -KILL "$pid" 2>/dev/null || true
echo "A_STOPPED=1 PID=$pid METHOD=kill"
