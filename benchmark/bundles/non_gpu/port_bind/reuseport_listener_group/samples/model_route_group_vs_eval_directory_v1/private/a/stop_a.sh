#!/usr/bin/env bash
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
IFS=, read -r -a workers <<< "$A_WORKER_IDS"
for worker in "${workers[@]}"; do pid=$(cat "$A_RUN_DIR/worker_${worker}.pid" 2>/dev/null || true); [ -z "$pid" ] || kill "$pid" 2>/dev/null || true; done
for worker in "${workers[@]}"; do
  pid=$(cat "$A_RUN_DIR/worker_${worker}.pid" 2>/dev/null || true)
  for _ in $(seq 1 40); do state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true); [ -z "$state" ] || [ "$state" = Z ] && break; sleep .05; done
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
done
printf 'A_STOPPED service=%s workers=%s\n' "$A_SERVICE_NAME" "$A_WORKERS"
