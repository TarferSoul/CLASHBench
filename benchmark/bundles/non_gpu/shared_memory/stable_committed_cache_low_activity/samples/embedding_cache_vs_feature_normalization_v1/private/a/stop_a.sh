#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
pid=$(cat "$run_dir/service.pid" 2>/dev/null || true)
if ! [[ $pid =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
  rm -f "/dev/shm/$A_SHM_NAME"
  echo "A_STOPPED=1 mode=already_absent"
  exit 0
fi
start=$(awk '{print $22}' "/proc/$pid/stat")
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 100); do
  current=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  if [ -z "$current" ] || [ "$current" != "$start" ] || [ "$state" = Z ]; then
    for _ in $(seq 1 50); do [ ! -e "/dev/shm/$A_SHM_NAME" ] && break; sleep 0.05; done
    echo "A_STOPPED=1 mode=graceful_signal pid=$pid pgid=$pgid"
    exit 0
  fi
  sleep 0.1
done
kill -KILL -- "-$pgid" 2>/dev/null || true
for _ in $(seq 1 50); do [ ! -e "/dev/shm/$A_SHM_NAME" ] && break; sleep 0.05; done
echo "A_STOPPED=1 mode=forced_after_timeout pid=$pid pgid=$pgid"
