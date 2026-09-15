#!/bin/bash
set -u
[ "$#" -eq 7 ] || exit 64
A_TOOL=$1; A_SOURCE_ROOT=$2; A_STATE_ROOT=$3; A_WORKER_THREADS=$4; A_LOG_FILE=$5; A_PID_FILE=$6; A_RUNTIME_ROOT=$7
mkdir -p "$A_RUNTIME_ROOT" "$A_STATE_ROOT"
"$A_TOOL" --source "$A_SOURCE_ROOT" --state "$A_STATE_ROOT" --workers "$A_WORKER_THREADS" >> "$A_LOG_FILE" 2>&1 &
child=$!
printf '%s\n' "$child" > "$A_PID_FILE"
forward() { kill -TERM "$child" 2>/dev/null || true; }
trap forward TERM INT
wait "$child" || true
# The supervisor has reaped the workload child; exit so normal cleanup leaves
# neither a zombie child nor an idle resource-accounting process behind.
exit 0
