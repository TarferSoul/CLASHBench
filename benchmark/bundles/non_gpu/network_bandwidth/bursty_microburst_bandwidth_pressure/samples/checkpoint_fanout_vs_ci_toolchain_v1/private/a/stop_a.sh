#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
state=${A_STATE_ROOT:-/run/media_burst_case/state}
for name in publisher receiver; do
  pid_file="$state/$name.pid"
  if [ -s "$pid_file" ]; then
    pid=$(cat "$pid_file")
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  fi
done
for _ in $(seq 1 100); do
  alive=0
  for name in publisher receiver; do
    [ -s "$state/$name.pid" ] && kill -0 "$(cat "$state/$name.pid")" 2>/dev/null && alive=1 || true
  done
  [ "$alive" = 0 ] && break
  sleep 0.03
done
echo "A_STOPPED=1"
