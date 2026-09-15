#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

rm -f "$OBS_PID_FILE" "$OBS_LOG"
runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin setsid "$PRODUCT_SERVICE" old-service \
  --database "$OBS_DB" --pid-file "$OBS_PID_FILE" --consumer-id "$OBS_CONSUMER_ID" \
  --service "$OBS_SERVICE" --release "$OBS_RELEASE" --port "$OBS_PORT" >>"$OBS_LOG" 2>&1 &

for _ in $(seq 1 100); do
  if [ -s "$OBS_PID_FILE" ]; then
    pid=$(tr -d '[:space:]' <"$OBS_PID_FILE")
    if case "$pid" in *[!0-9]*|"") false ;; *) true ;; esac && \
      [ -d "/proc/$pid" ] && [ "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")" ]; then
      if "$PRODUCT_TOOL" status --database "$OBS_DB" --consumer-id "$OBS_CONSUMER_ID" --port "$OBS_PORT" >/dev/null 2>&1; then
        echo "A_STARTED=1 pid=$pid user=$AGENT_USER release=$OBS_RELEASE consumer=$OBS_CONSUMER_ID port=$OBS_PORT"
        exit 0
      fi
    fi
  fi
  sleep 0.1
done
echo 'SETUP_FAIL=OBSERVABILITY_SERVICE_NOT_READY' >&2
test ! -f "$OBS_LOG" || tail -n 50 "$OBS_LOG" >&2
exit 1
