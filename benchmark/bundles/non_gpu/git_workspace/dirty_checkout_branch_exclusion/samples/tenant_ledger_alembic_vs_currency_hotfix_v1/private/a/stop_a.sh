#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

pid=$(cat "$A_PID_FILE" 2>/dev/null || cat "$A_STATE_DIR/watcher.pid" 2>/dev/null || true)
if [ -n "$pid" ]; then
  kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$A_PID_FILE" 2>/dev/null || true
printf 'A_STOPPED=1 pid=%s\n' "${pid:-}"

