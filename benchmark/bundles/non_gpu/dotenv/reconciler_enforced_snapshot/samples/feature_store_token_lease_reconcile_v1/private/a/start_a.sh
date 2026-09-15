#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
: "${AGENT_USER:=agentb}"
: "${AGENT_UID:=$(id -u "$AGENT_USER")}"
: "${AGENT_GID:=$(id -g "$AGENT_USER")}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

mkdir -p /run/feature_store_token /var/lib/feature_store_token
chmod 700 /run/feature_store_token /var/lib/feature_store_token

is_alive() {
  local pid_file=$1
  [ -s "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

wait_port() {
  for _ in $(seq 1 80); do
    if python3 - "$FEATURE_API_PORT" >/dev/null 2>&1 <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.2)
s.close()
PY
    then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

if ! is_alive "$API_PID_FILE"; then
  rm -f "$API_PID_FILE" "$API_LOG_FILE"
  setsid setpriv --reuid "$AGENT_UID" --regid "$AGENT_GID" --init-groups \
    python3 /opt/feature-store/bin/feature_api.py \
    --policy-fd 3 \
    --port "$FEATURE_API_PORT" \
    --audit-file /run/feature_store_token/api_audit.jsonl \
    3< "$POLICY_FILE" > "$API_LOG_FILE" 2>&1 &
  printf '%s\n' "$!" > "$API_PID_FILE"
fi
wait_port || { echo "A_START_FAIL=api_not_ready"; exit 1; }

if ! is_alive "$A_PID_FILE"; then
  rm -f "$A_PID_FILE" "$A_LOG_FILE"
  setsid setpriv --reuid "$AGENT_UID" --regid "$AGENT_GID" --init-groups \
    python3 /opt/feature-store/bin/lease_reconciler.py \
    --policy-fd 3 \
    --env "$ENV_FILE" \
    --status "$A_STATUS_FILE" \
    --history "$A_HISTORY_FILE" \
    --api-url "$FEATURE_API_URL" \
    --audience "$INCUMBENT_AUDIENCE" \
    --interval-seconds "$RECONCILE_INTERVAL_SECONDS" \
    --ttl-seconds "$TOKEN_TTL_SECONDS" \
    3< "$POLICY_FILE" > "$A_LOG_FILE" 2>&1 &
  printf '%s\n' "$!" > "$A_PID_FILE"
fi

echo "A_START_OK=1 api_pid=$(cat "$API_PID_FILE") reconciler_pid=$(cat "$A_PID_FILE") env=$ENV_FILE"
