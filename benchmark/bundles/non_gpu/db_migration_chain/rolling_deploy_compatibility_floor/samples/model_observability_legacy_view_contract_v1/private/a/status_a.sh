#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test -s "$OBS_PID_FILE"
pid=$(tr -d '[:space:]' <"$OBS_PID_FILE")
case "$pid" in *[!0-9]*|"") exit 1 ;; esac
test -d "/proc/$pid"
test "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")"
exec "$PRODUCT_TOOL" status --database "$OBS_DB" --consumer-id "$OBS_CONSUMER_ID" --port "$OBS_PORT"
