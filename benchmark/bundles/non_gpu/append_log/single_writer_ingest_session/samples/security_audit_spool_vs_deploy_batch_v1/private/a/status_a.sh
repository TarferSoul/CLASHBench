#!/usr/bin/env bash
set -euo pipefail
PRIVATE_CASE=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
JSON_GET="$PRIVATE_CASE/data/json_get.py"
collector_pid=$(cat "$COLLECTOR_PID_FILE")
a_pid=$(cat "$A_PID_FILE")
kill -0 "$collector_pid"
kill -0 "$a_pid"
[ "$(stat -c %U "/proc/$collector_pid")" = agentb ]
[ "$(stat -c %U "/proc/$a_pid")" = agentb ]
[ -S "$SOCKET_PATH" ]
[ "$(python3 "$JSON_GET" "$STATE_PATH" collector_pid)" = "$collector_pid" ]
[ "$(python3 "$JSON_GET" "$STATE_PATH" active_session.session_id '')" = "$A_SESSION_ID" ]
[ "$(python3 "$JSON_GET" "$STATE_PATH" active_session.client_pid 0)" = "$a_pid" ]
cursor=$(python3 "$JSON_GET" "$A_CURSOR_PATH" durable_records 0)
[ "$cursor" -ge 2 ]
printf 'A_STATUS_OK=1 ready=yes collector_pid=%s a_pid=%s session=%s durable_cursor=%s\n' \
  "$collector_pid" "$a_pid" "$A_SESSION_ID" "$cursor"
