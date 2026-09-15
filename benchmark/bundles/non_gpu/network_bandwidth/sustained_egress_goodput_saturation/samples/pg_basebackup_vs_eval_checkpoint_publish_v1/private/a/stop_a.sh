#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/fixture.env"
state=${A_STATE_ROOT:?}
scope=${STOP_SCOPE:-all}
case "$scope" in publisher|all) ;; *) echo "unknown STOP_SCOPE=$scope" >&2; exit 2 ;; esac
stop_one() {
  local label=$1 pid_file="$state/$1.pid" pid
  [ -s "$pid_file" ] || return 0
  pid=$(cat "$pid_file")
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep .03; done
  kill -KILL "$pid" 2>/dev/null || true
  echo "STOPPED label=$label pid=$pid"
}
stop_one publisher
if [ "$scope" = all ]; then
  stop_one gateway
  stop_one receiver
fi
echo "A_STOPPED=1 scope=$scope"
