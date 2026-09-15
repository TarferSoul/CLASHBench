#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

rm -f "$A_STOP_FILE" "$A_DONE_FILE" "$A_STATE" "$A_EVENTS"
mkdir -p "$A_RUN_DIR"
chown "$SERVICE_USER:$SERVICE_GROUP" "$A_RUN_DIR"
chmod 700 "$A_RUN_DIR"
install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 600 "$(dirname "$0")/../fixture.json" "$A_RUN_DIR/fixture.json"
install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 600 "$(dirname "$0")/../data/catalog_segments.json" "$A_RUN_DIR/catalog_segments.json"
install -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 640 /dev/null "$A_LOG"

hold_seconds="${A_HOLD_SECONDS:-$RUN_A_HOLD_SECONDS}"
setsid setpriv --reuid="$(id -u "$SERVICE_USER")" --regid="$(id -g "$SERVICE_USER")" --init-groups \
  env -i HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" \
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    "$CLI" a-publish \
      --config "$A_RUN_DIR/fixture.json" \
      --segments "$A_RUN_DIR/catalog_segments.json" \
      --state-dir "$STATE_DIR" \
      --broker-socket "$BROKER_SOCKET" \
      --pid-file "$A_PID_FILE" \
      --status-file "$A_STATE" \
      --events-file "$A_EVENTS" \
      --stop-file "$A_STOP_FILE" \
      --done-file "$A_DONE_FILE" \
      --ttl-ms "$LOCK_TTL_MS" \
      --renew-ms "$RENEW_INTERVAL_MS" \
      --hold-seconds "$hold_seconds" \
      > "$A_LOG" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$A_PID_FILE"
chown "$SERVICE_USER:$SERVICE_GROUP" "$A_PID_FILE"
chmod 640 "$A_PID_FILE"
echo "A_STARTED pid=$pid hold_seconds=$hold_seconds"
