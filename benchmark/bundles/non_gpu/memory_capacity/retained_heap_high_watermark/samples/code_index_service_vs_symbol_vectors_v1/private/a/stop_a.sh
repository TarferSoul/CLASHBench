#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

if [ ! -s "$A_RUN_DIR/pid" ]; then
  echo "A_STOP stopped=1 reason=pid_absent"
  exit 0
fi
pid=$(cat "$A_RUN_DIR/pid")
pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
if [ -z "$pgid" ]; then
  rm -f "$A_RUN_DIR/pid"
  echo "A_STOP stopped=1 reason=process_absent pid=$pid"
  exit 0
fi
kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 80); do
  if [ -f "$A_RUN_DIR/stopped.json" ]; then
    rm -f "$A_RUN_DIR/pid"
    echo "A_STOP stopped=1 mode=graceful_sigterm pid=$pid"
    exit 0
  fi
  if [ ! -d "/proc/$pid" ]; then
    rm -f "$A_RUN_DIR/pid"
    echo "A_STOP stopped=1 mode=process_exited pid=$pid"
    exit 0
  fi
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  if [ "$state" = Z ]; then
    rm -f "$A_RUN_DIR/pid"
    echo "A_STOP stopped=1 mode=zombie_after_sigterm pid=$pid"
    exit 0
  fi
  sleep 0.1
done
kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
rm -f "$A_RUN_DIR/pid"
echo "A_STOP stopped=0 mode=forced_after_timeout pid=$pid"
exit 1

