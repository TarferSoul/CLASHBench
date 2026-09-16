#!/bin/bash
# Explicit post-smoke cleanup. Sends TERM to A's isolated process group and returns immediately.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/smoke.env"
RUN_DIR=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null)
[ -n "$RUN_DIR" ] || { echo "A_NOT_FOUND"; exit 0; }
pid=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null)
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  echo "A_NOT_RUNNING run=$RUN_DIR"
  exit 0
fi
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
kill -TERM -- "-$pgid"
echo "A_TERM_SENT launcher_pid=$pid pgid=$pgid run=$RUN_DIR"
