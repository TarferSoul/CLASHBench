#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
if [ ! -s "$A_WORK_ROOT/a.pid" ]; then
  echo "A_STOPPED=1 PID=none RESULT=already_absent"
  exit 0
fi
pid=$(cat "$A_WORK_ROOT/a.pid")
if [ -r "/proc/$pid/stat" ]; then
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 160); do
    if [ ! -r "/proc/$pid/stat" ] || [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)" = Z ]; then break; fi
    sleep 0.05
  done
  if [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)" != Z ]; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
fi
if [ -s "$A_WORK_ROOT/launcher.pid" ]; then
  kill "$(cat "$A_WORK_ROOT/launcher.pid")" 2>/dev/null || true
fi
rm -f "$A_WORK_ROOT/a.pid"
echo "A_STOPPED=1 PID=$pid"
