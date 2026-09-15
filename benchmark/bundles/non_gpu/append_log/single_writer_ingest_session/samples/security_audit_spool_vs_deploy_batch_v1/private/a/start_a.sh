#!/usr/bin/env bash
set -euo pipefail
PRIVATE_CASE=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
JSON_GET="$PRIVATE_CASE/data/json_get.py"

rm -f "$SOCKET_PATH" "$STATE_PATH" "$COLLECTOR_PID_FILE" "$A_PID_FILE" "$A_CURSOR_PATH" "$A_RECEIPT_PATH"
touch "$A_LOG_PATH"
chown agentb:agentb "$A_LOG_PATH"

setsid bash -c '
  set -e
  ledger=$1
  shift
  exec 3>>"$ledger"
  exec setpriv --reuid=agentb --regid=agentb --init-groups "$@"
' bash "$LEDGER_PATH" "$INSTALL_ROOT/bin/$COLLECTOR_COMMAND" \
  --socket "$SOCKET_PATH" --state "$STATE_PATH" --token "$AUTH_TOKEN" --log-fd 3 \
  > "$RUNTIME_ROOT/collector.log" 2>&1 &
collector_pid=$!
printf '%s\n' "$collector_pid" > "$COLLECTOR_PID_FILE"

ready=0
for _ in $(seq 1 100); do
  if kill -0 "$collector_pid" 2>/dev/null && [ -S "$SOCKET_PATH" ] && [ -s "$STATE_PATH" ]; then
    ready=1
    break
  fi
  sleep .05
done
[ "$ready" = 1 ] || { tail -80 "$RUNTIME_ROOT/collector.log" >&2 || true; exit 1; }

if [ "${START_A_MODE:-full}" = collector_only ]; then
  printf 'COLLECTOR_READY=1 pid=%s socket=%s\n' "$collector_pid" "$SOCKET_PATH"
  exit 0
fi

setsid setpriv --reuid=agentb --regid=agentb --init-groups \
  "$INSTALL_ROOT/bin/$A_CLIENT_COMMAND" \
  --socket "$SOCKET_PATH" --token-file "$TOKEN_FILE" --input "$A_SPOOL_PATH" \
  --receipt "$A_RECEIPT_PATH" --cursor "$A_CURSOR_PATH" \
  --session-id "$A_SESSION_ID" --context "$A_CONTEXT" --delay-ms "$A_DELAY_MS" \
  > "$A_LOG_PATH" 2>&1 &
a_pid=$!
printf '%s\n' "$a_pid" > "$A_PID_FILE"

ready=0
for _ in $(seq 1 150); do
  if kill -0 "$a_pid" 2>/dev/null && [ -s "$A_CURSOR_PATH" ] \
    && [ "$(python3 "$JSON_GET" "$STATE_PATH" active_session.session_id '')" = "$A_SESSION_ID" ] \
    && [ "$(python3 "$JSON_GET" "$A_CURSOR_PATH" durable_records 0)" -ge 2 ]; then
    ready=1
    break
  fi
  sleep .1
done
[ "$ready" = 1 ] || { tail -80 "$A_LOG_PATH" >&2 || true; exit 1; }
printf 'A_STARTED=1 collector_pid=%s a_pid=%s session=%s\n' "$collector_pid" "$a_pid" "$A_SESSION_ID"
