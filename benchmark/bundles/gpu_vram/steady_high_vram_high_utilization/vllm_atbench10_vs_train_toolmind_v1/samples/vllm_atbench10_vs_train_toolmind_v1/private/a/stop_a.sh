#!/bin/bash
# Explicit cleanup: signal the isolated incumbent process group and return.
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
[ -n "$RUN_DIR" ] || { echo "A_NOT_FOUND"; exit 0; }
pid=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null || true)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "A_NOT_RUNNING run=$RUN_DIR"
  exit 0
fi
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
kill -TERM -- "-$pgid"
echo "A_TERM_SENT launcher_pid=$pid pgid=$pgid run=$RUN_DIR"
