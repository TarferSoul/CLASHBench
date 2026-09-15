#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

stop_pid_file() {
  local file=$1
  [ -s "$file" ] || return 0
  local pid
  pid=$(cat "$file")
  [ -n "$pid" ] || return 0
  if [ -d "/proc/$pid" ]; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      [ ! -d "/proc/$pid" ] && break
      state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo Z)
      [ "$state" = Z ] && break
      sleep 0.1
    done
    if [ -d "/proc/$pid" ]; then
      state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo Z)
      [ "$state" = Z ] || kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$file"
}

stop_pid_file "$A_PID_FILE"
stop_pid_file "$GATEWAY_PID_FILE"
echo "A_STOPPED=1"

