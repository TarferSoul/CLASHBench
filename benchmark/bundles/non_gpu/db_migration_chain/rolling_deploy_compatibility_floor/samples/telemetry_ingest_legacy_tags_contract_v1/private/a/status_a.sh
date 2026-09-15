#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test -s "$TELEMETRY_PID_FILE"
pid=$(tr -d '[:space:]' <"$TELEMETRY_PID_FILE")
case "$pid" in *[!0-9]*|"") exit 1 ;; esac
test -d "/proc/$pid"
test "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")"
exec "$PRODUCT_TOOL" status --database "$TELEMETRY_DB" --consumer-id "$TELEMETRY_CONSUMER_ID"
