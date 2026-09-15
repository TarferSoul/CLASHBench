#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
pid=$(cat "$run_dir/mirror.pid" 2>/dev/null || true)
launcher_pid=$(cat "$run_dir/launcher.pid" 2>/dev/null || true)
if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 25); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
fi
[ -n "${launcher_pid:-}" ] && kill "$launcher_pid" 2>/dev/null || true
rm -f "$A_RUN_ROOT/current"
echo "A_STOPPED=1 pid=${pid:-none}"
