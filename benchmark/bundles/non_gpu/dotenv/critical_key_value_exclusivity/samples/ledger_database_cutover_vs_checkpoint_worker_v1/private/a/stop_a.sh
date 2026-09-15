#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"
if [ ! -s "$A_PID_FILE" ]; then
  echo 'A_STOPPED=1 already_absent=1'
  exit 0
fi
pid=$(cat "$A_PID_FILE")
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    if [ ! -d "/proc/$pid" ]; then
      break
    fi
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo gone)
    [ "$state" != Z ] || break
    sleep 0.1
  done
  if [ -d "/proc/$pid" ] && [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo gone)" != Z ]; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
fi
rm -f "$A_PID_FILE"
printf 'A_STOPPED=1 pid=%s\n' "$pid"
