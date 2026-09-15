#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
ENV_FILE="$SCRIPT_DIR/routectl.env"

if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

CONFIG_PATH=${1:-$WORK_ROOT/configs/us-east-1-api-router-standby-drain.json}
OUTPUT_PATH=${2:-$WORK_ROOT/route_reconcile/report.json}

python3 "$SCRIPT_DIR/routectl.py" reconcile \
  --config "$CONFIG_PATH" \
  --output "$OUTPUT_PATH" \
  --redis-host "${REDIS_HOST:?}" \
  --redis-port "${REDIS_PORT:?}" \
  --redis-db "${REDIS_DB:?}" \
  --leader-key "${LEADER_KEY:?}" \
  --epoch-key "${EPOCH_KEY:?}" \
  --meta-key "${META_KEY:?}" \
  --route-state-key "${ROUTE_STATE_KEY:?}" \
  --route-epoch-key "${ROUTE_EPOCH_KEY:?}" \
  --reconcile-log-key "${RECONCILE_LOG_KEY:?}" \
  --lease-ttl-ms "${LEASE_TTL_MS:?}" \
  --election-timeout-ms "${B_ELECTION_TIMEOUT_MS:?}" \
  --retry-interval-ms "${B_RETRY_INTERVAL_MS:?}"

