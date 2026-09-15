#!/bin/bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

pid=""
pgid=""
[ ! -s "$A_PID_FILE" ] || pid=$(cat "$A_PID_FILE")
[ ! -s "$A_RUNTIME_ROOT/service.pgid" ] || pgid=$(cat "$A_RUNTIME_ROOT/service.pgid")
if [ -n "$pgid" ] && kill -0 "-$pgid" 2>/dev/null; then
  kill -TERM "-$pgid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "-$pgid" 2>/dev/null || break
    sleep 0.05
  done
  kill -KILL "-$pgid" 2>/dev/null || true
elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$A_PID_FILE"
printf 'A_STOPPED=1 PID=%s PGID=%s\n' "${pid:-none}" "${pgid:-none}"

