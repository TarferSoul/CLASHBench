#!/bin/bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

RUN=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
pid=
[ -n "$RUN" ] && pid=$(cat "$RUN/worker.pid" 2>/dev/null || true)

if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "A_STOPPED already_stopped=1 run=${RUN:-none}"
  exit 0
fi

pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
if [ -n "$pgid" ]; then
  kill -TERM "-$pgid" 2>/dev/null || true
else
  kill -TERM "$pid" 2>/dev/null || true
fi

for _ in $(seq 1 30); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done

if kill -0 "$pid" 2>/dev/null; then
  if [ -n "$pgid" ]; then
    kill -KILL "-$pgid" 2>/dev/null || true
  else
    kill -KILL "$pid" 2>/dev/null || true
  fi
fi

echo "A_STOPPED pid=$pid run=${RUN:-none}"

