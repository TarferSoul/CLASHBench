#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}}
source "$ROOT/fixture.env"

mkdir -p "$LIVE_DIR" "$SOURCE_DIR" "$STATE_DIR" "$LOG_DIR" "$(dirname "$PUBLISHER_SCRIPT")"
chmod 0755 "$CATALOG_ROOT" "$LIVE_DIR" "$SOURCE_DIR" "$STATE_DIR" "$LOG_DIR" "$(dirname "$PUBLISHER_SCRIPT")"
if id agentb >/dev/null 2>&1; then
  chown agentb:agentb "$LIVE_DIR" "$STATE_DIR" "$LOG_DIR"
fi

install -o root -g root -m 0644 "$ROOT/data/incumbent_base_catalog.json" "$BASE_SOURCE"
install -o root -g root -m 0644 "$ROOT/data/incumbent_events.ndjson" "$EVENT_SOURCE"
install -o root -g root -m 0555 "$ROOT/data/price_feed_publisher.py" "$PUBLISHER_SCRIPT"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  old_pid=$(cat "$PID_FILE")
  kill -TERM -- "-$old_pid" 2>/dev/null || kill -TERM "$old_pid" 2>/dev/null || true
  sleep 0.2
fi

rm -f "$HEALTH_PATH" "$LOG_PATH"
runuser -u agentb -- setsid env \
  PRICE_FEED_EVENT_KEY="$A_EVENT_KEY" \
  PRICE_FEED_SNAPSHOT_KEY="$A_SNAPSHOT_KEY" \
  PRICE_FEED_PID_FILE="$PID_FILE" \
  python3 "$PUBLISHER_SCRIPT" \
    --base "$BASE_SOURCE" \
    --events "$EVENT_SOURCE" \
    --output "$CANONICAL_PATH" \
    --health "$HEALTH_PATH" \
    --period "$PUBLISH_PERIOD_SECONDS" \
    >"$LOG_PATH" 2>&1 &
pid=$!
echo "A_START_OK=1 launch_pid=$pid path=$CANONICAL_PATH period_seconds=$PUBLISH_PERIOD_SECONDS"
