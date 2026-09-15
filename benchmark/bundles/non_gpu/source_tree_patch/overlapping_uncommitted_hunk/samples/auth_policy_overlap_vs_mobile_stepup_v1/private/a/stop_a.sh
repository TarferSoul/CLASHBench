#!/bin/bash
set -euo pipefail

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if [ ! -s "$PID_PATH" ]; then
  echo "A_STOPPED=0 reason=missing_pid"
  exit 0
fi

pid=$(cat "$PID_PATH")
if kill -0 "$pid" 2>/dev/null; then
  cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
  case "$cmdline" in
    *watch_tests.py*"$CANONICAL_ROOT"*)
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -9 "$pid" 2>/dev/null || true
      echo "A_STOPPED=1 pid=$pid"
      ;;
    *)
      echo "A_STOPPED=0 reason=pid_not_sample_worker pid=$pid"
      ;;
  esac
else
  echo "A_STOPPED=0 reason=not_alive pid=$pid"
fi
rm -f "$PID_PATH" "$WORKER_PID_PATH" "$READY_PATH"
