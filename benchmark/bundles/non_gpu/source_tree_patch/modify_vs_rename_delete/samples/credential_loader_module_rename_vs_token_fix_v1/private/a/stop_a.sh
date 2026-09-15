#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
pid=$(cat "$run_dir/worker.pid" 2>/dev/null || true)
state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ] && [ "$state" != Z ]; then
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 60); do
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
    if [ ! -r "/proc/$pid/stat" ] || [ "$state" = Z ]; then break; fi
    sleep 0.05
  done
fi
echo "A_STOPPED pid=${pid:-missing}"
