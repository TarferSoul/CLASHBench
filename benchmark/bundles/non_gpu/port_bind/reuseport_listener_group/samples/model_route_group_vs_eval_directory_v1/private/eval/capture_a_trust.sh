#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
bash "$ROOT/a/status_a.sh" >/dev/null; IFS=, read -r -a workers <<< "$A_WORKER_IDS"; tmp="$A_TRUST_FILE.tmp"
{
  printf 'A_SERVICE_NAME=%q\nA_HOST=%q\nA_PORT=%q\nA_WORKER_IDS=%q\nA_WORKER_COUNT=%q\n' "$A_SERVICE_NAME" "$A_HOST" "$A_PORT" "$A_WORKER_IDS" "$A_WORKERS"
  all_inodes=()
  for worker in "${workers[@]}"; do
    pid=$(cat "$A_RUN_DIR/worker_${worker}.pid"); start=$(awk '{print $22}' "/proc/$pid/stat"); pgid=$(awk '{print $5}' "/proc/$pid/stat"); uid=$(stat -c %u "/proc/$pid"); inode=$(cat "$A_RUN_DIR/worker_${worker}.socket_inode"); key=$(printf '%s' "$worker" | tr '[:lower:]-' '[:upper:]_')
    printf 'A_%s_PID=%q\nA_%s_STARTTIME=%q\nA_%s_PGID=%q\nA_%s_UID=%q\nA_%s_SOCKET_INODE=%q\n' "$key" "$pid" "$key" "$start" "$key" "$pgid" "$key" "$uid" "$key" "$inode"; all_inodes+=("$inode")
  done
  printf 'A_SOCKET_INODES=%q\n' "$(IFS=,; echo "${all_inodes[*]}")"
} >"$tmp"
mv "$tmp" "$A_TRUST_FILE"; chmod 600 "$A_TRUST_FILE"; printf 'A_TRUST_CAPTURED=1 workers=%s transport=UDP\n' "$A_WORKERS"
