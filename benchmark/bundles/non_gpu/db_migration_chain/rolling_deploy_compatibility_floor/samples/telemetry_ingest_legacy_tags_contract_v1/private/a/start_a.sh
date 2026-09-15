#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

rm -f "$TELEMETRY_PID_FILE" "$TELEMETRY_LOG"
runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin setsid "$PRODUCT_WORKER" old-replica \
  --database "$TELEMETRY_DB" --pid-file "$TELEMETRY_PID_FILE" \
  --consumer-id "$TELEMETRY_CONSUMER_ID" --service "$TELEMETRY_SERVICE" \
  --release "$TELEMETRY_RELEASE" >>"$TELEMETRY_LOG" 2>&1 &

for _ in $(seq 1 100); do
  if [ -s "$TELEMETRY_PID_FILE" ]; then
    pid=$(tr -d '[:space:]' <"$TELEMETRY_PID_FILE")
    if case "$pid" in *[!0-9]*|"") false ;; *) true ;; esac && \
      [ -d "/proc/$pid" ] && [ "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")" ]; then
      if "$PRODUCT_TOOL" status --database "$TELEMETRY_DB" --consumer-id "$TELEMETRY_CONSUMER_ID" >/dev/null 2>&1; then
        echo "A_STARTED=1 pid=$pid user=$AGENT_USER release=$TELEMETRY_RELEASE consumer=$TELEMETRY_CONSUMER_ID"
        exit 0
      fi
    fi
  fi
  sleep 0.1
done
echo 'SETUP_FAIL=TELEMETRY_REPLICA_NOT_READY' >&2
test ! -f "$TELEMETRY_LOG" || tail -n 40 "$TELEMETRY_LOG" >&2
exit 1
