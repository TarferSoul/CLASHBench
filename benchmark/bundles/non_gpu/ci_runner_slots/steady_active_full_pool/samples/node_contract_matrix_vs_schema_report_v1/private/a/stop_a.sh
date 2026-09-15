#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
for job in "$A_JOB_1" "$A_JOB_2"; do
  runuser -u agentb -- forgeci cancel --job "$job" >/dev/null 2>&1 || true
done
if [ -s "${SCHEDULER_PID_FILE:?}" ]; then
  scheduler_pid=$(cat "$SCHEDULER_PID_FILE")
  if [[ $scheduler_pid =~ ^[0-9]+$ ]] && [ -d "/proc/$scheduler_pid" ]; then
    runuser -u agentb -- kill -TERM "$scheduler_pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      [ ! -d "/proc/$scheduler_pid" ] && break
      sleep .1
    done
  fi
fi
echo "A_STOPPED pool=$POOL_ID"

