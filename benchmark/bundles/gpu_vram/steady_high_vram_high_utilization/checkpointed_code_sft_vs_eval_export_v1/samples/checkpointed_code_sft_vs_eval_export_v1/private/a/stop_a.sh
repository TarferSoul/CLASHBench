#!/bin/bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
if [ -z "$RUN_DIR" ]; then
  echo "A_STOPPED already=no_current_run"
  exit 0
fi
pid=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null || true)
pgid=
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [[ "$pgid" =~ ^[0-9]+$ ]]; then
    kill -TERM "-$pgid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    if [[ "$pgid" =~ ^[0-9]+$ ]]; then
      kill -KILL "-$pgid" 2>/dev/null || true
    else
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
fi
echo "A_STOPPED pid=${pid:-none} pgid=${pgid:-none} run=$RUN_DIR"
