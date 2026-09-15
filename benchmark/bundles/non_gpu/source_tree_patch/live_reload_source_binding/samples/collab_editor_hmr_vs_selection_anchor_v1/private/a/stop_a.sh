#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}
# shellcheck disable=SC1090
. "$CASE_DIR/fixture.env"

state=${A_STATE_ROOT:-/run/cb_live_reload/state/manual}

stop_pid() {
  local pid_file=$1
  local start_file=$2
  [ -f "$pid_file" ] || return 0
  local pid
  pid=$(cat "$pid_file" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  if [ -f "$start_file" ] && [ -r "/proc/$pid/stat" ]; then
    local expected actual
    expected=$(cat "$start_file" 2>/dev/null || true)
    actual=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
    [ -z "$expected" ] || [ "$expected" = "$actual" ] || return 0
  fi
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    [ ! -e "/proc/$pid" ] && return 0
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
}

stop_pid "$state/client.pid" "$state/client.start"
stop_pid "$state/server.pid" "$state/server.start"
echo "A_STOPPED=1 state=$state"
