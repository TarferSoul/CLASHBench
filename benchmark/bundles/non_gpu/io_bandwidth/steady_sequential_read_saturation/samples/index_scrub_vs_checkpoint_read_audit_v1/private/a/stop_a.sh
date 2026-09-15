#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$ROOT/fixture.env"
set +a

if [ ! -s "$A_STATE_ROOT/supervisor.pid" ]; then
  echo "A_STOPPED already=1"
  exit 0
fi
pid=$(cat "$A_STATE_ROOT/supervisor.pid")
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$pgid" ]; then
    kill -TERM "-$pgid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    [ -n "${pgid:-}" ] && kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
fi
rm -f "$A_STATE_ROOT/supervisor.pid"
echo "A_STOPPED pid=${pid:-none}"
