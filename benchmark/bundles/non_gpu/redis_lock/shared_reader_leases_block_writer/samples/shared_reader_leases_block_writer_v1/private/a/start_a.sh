#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rm -rf "$A_RUNS_ROOT"
mkdir -p "$A_RUNS_ROOT"
for index in 1 2; do
  state="$A_RUNS_ROOT/reader_$index"
  mkdir -p "$state"
  chown agentb:agentb "$state"
  runuser -u agentb -- env HOME=/home/agentb PATH="$PATH" \
    REDIS_HOST="$REDIS_HOST" REDIS_PORT="$REDIS_PORT" REDIS_DB="$REDIS_DB" \
    LOCK_KEY="$LOCK_KEY" READER_SET_KEY="$READER_SET_KEY" WRITER_KEY="$WRITER_KEY" \
    READER_OWNER_PREFIX="$READER_OWNER_PREFIX" ACTIVE_KEY="$ACTIVE_KEY" \
    FENCE_KEY="$FENCE_KEY" GENERATION_PREFIX="$GENERATION_PREFIX" \
    READER_TTL_SECONDS="$READER_TTL_SECONDS" RENEW_INTERVAL_SECONDS="$RENEW_INTERVAL_SECONDS" \
    DATA_ROOT="$DATA_ROOT" python3 "$A_WORKER_ROOT/a/reader_worker.py" --index "$index" --state "$state" \
    >"$state/worker.log" 2>&1 < /dev/null &
  echo "$!" > "$state/launcher.pid"
done
echo "A_STARTED readers=2 root=$A_RUNS_ROOT"
