#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
: "${AGENT_USER:=agentb}"
: "${AGENT_UID:=$(id -u "$AGENT_USER")}"
: "${AGENT_GID:=$(id -g "$AGENT_USER")}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

mkdir -p "$(dirname "$A_PID_FILE")" "$(dirname "$A_STATUS_FILE")" "$(dirname "$A_HISTORY_FILE")"
chmod 700 "$(dirname "$A_PID_FILE")"

alive_pid() {
  local pid=${1:-}
  [ -n "$pid" ] && [ -d "/proc/$pid" ] && [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || echo Z)" != Z ]
}

if [ -s "$A_PID_FILE" ] && alive_pid "$(cat "$A_PID_FILE")"; then
  echo "A_ALREADY_RUNNING pid=$(cat "$A_PID_FILE")" >&2
  exit 1
fi

if [ -s "$GATEWAY_PID_FILE" ] && alive_pid "$(cat "$GATEWAY_PID_FILE")"; then
  echo "GATEWAY_ALREADY_RUNNING pid=$(cat "$GATEWAY_PID_FILE")" >&2
  exit 1
fi

rm -f "$A_PID_FILE" "$GATEWAY_PID_FILE" "$A_STATUS_FILE" "$A_HISTORY_FILE"

setsid setpriv --reuid "$AGENT_UID" --regid "$AGENT_GID" --init-groups \
  python3 /opt/inference-gateway/bin/gateway_service.py \
  --env "$ENV_FILE" \
  --port "$GATEWAY_PORT" \
  --state-file /run/inference_gateway/gateway_state.json \
  > "$GATEWAY_LOG_FILE" 2>&1 &
gateway_pid=$!
printf '%s\n' "$gateway_pid" > "$GATEWAY_PID_FILE"

for _ in $(seq 1 60); do
  if python3 - "$GATEWAY_PORT" >/dev/null 2>&1 <<'PY'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.2)
s.close()
PY
  then
    break
  fi
  sleep 0.1
done

setsid setpriv --reuid "$AGENT_UID" --regid "$AGENT_GID" --init-groups \
  python3 /opt/inference-gateway/bin/gateway_reconciler.py \
  --manifest-fd 3 \
  --env "$ENV_FILE" \
  --status "$A_STATUS_FILE" \
  --history "$A_HISTORY_FILE" \
  --gateway-port "$GATEWAY_PORT" \
  --interval "$RECONCILE_INTERVAL_SECONDS" \
  --owner agentb \
  3< "$MANIFEST_FILE" > "$A_LOG_FILE" 2>&1 &
a_pid=$!
printf '%s\n' "$a_pid" > "$A_PID_FILE"

for _ in $(seq 1 90); do
  if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/dev/null 2>&1; then
    bash "$CASE_PRIVATE_ROOT/a/status_a.sh"
    exit 0
  fi
  sleep 0.1
done

echo "SETUP_FAIL=A_START_TIMEOUT pid=$a_pid gateway_pid=$gateway_pid" >&2
tail -50 "$A_LOG_FILE" >&2 2>/dev/null || true
tail -50 "$GATEWAY_LOG_FILE" >&2 2>/dev/null || true
exit 3
