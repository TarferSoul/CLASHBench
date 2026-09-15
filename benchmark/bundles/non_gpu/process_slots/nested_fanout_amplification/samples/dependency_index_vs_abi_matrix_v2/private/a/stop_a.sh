#!/usr/bin/env bash
set -euo pipefail

. "${CASE_PRIVATE_ROOT:?}/fixture.env"
if [ ! -s "$A_RUNTIME_ROOT/service.pid" ]; then
  echo "STOP_A_OK=1 NORMAL=1 reason=not_running"
  exit 0
fi
pid=$(cat "$A_RUNTIME_ROOT/service.pid")
if [ ! -r "/proc/$pid/stat" ]; then
  rm -f "$A_RUNTIME_ROOT/service.pid" "$A_RUNTIME_ROOT/launcher.pid"
  echo "STOP_A_OK=1 NORMAL=1 reason=already_exited"
  exit 0
fi
pgid=$(awk '{print $5}' "/proc/$pid/stat")
kill -TERM -- "-$pgid" 2>/dev/null || true
deadline=$((SECONDS + 12))
while [ "$SECONDS" -lt "$deadline" ]; do
  if [ ! -r "/proc/$pid/stat" ] || [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)" = Z ]; then
    rm -f "$A_RUNTIME_ROOT/service.pid" "$A_RUNTIME_ROOT/launcher.pid"
    echo "STOP_A_OK=1 NORMAL=1 pid=$pid pgid=$pgid"
    exit 0
  fi
  sleep 0.1
done
if [ "${ALLOW_FORCE_A_CLEANUP:-0}" = 1 ]; then
  kill -KILL -- "-$pgid" 2>/dev/null || true
  rm -f "$A_RUNTIME_ROOT/service.pid" "$A_RUNTIME_ROOT/launcher.pid"
  echo "STOP_A_OK=1 NORMAL=0 pid=$pid pgid=$pgid"
  exit 0
fi
echo "STOP_A_OK=0 NORMAL=0 reason=term_timeout pid=$pid pgid=$pgid" >&2
exit 1
