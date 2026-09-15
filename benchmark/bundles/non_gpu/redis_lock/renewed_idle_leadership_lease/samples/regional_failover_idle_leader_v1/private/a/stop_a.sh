#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?}"
: "${A_RUN_ROOT:?}"

pid_file="$A_RUN_ROOT/controller.pid"
if [ ! -s "$pid_file" ]; then
  echo "A_STOPPED=1 reason=no_pid_file"
  exit 0
fi

pid=$(cat "$pid_file")
if kill -0 "$pid" 2>/dev/null; then
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "A_STOPPED=1 reason=normal_term"
      exit 0
    fi
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
    if [ "$state" = Z ]; then
      echo "A_STOPPED=1 reason=zombie_after_term"
      exit 0
    fi
    sleep 0.05
  done
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
fi

echo "A_STOPPED=1 reason=forced_or_already_gone"

