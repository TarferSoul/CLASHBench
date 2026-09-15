#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"

process_alive() {
  local pid=$1 state
  [ -n "$pid" ] && [ -r "/proc/$pid/stat" ] || return 1
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  [ "$state" != Z ]
}

for pid_file in "$NGINX_PID_FILE" "$A_BACKEND_PID_FILE" "$A_PROBE_PID_FILE"; do
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if process_alive "$pid"; then
    echo "A_ALREADY_RUNNING pid=$pid file=$pid_file" >&2
    exit 1
  fi
done

uid=$(id -u agentb)
gid=$(id -g agentb)
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/preflight.sh"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/configure_gateway.sh" fallback
rm -rf "$A_RUN_ROOT"
install -d -o agentb -g agentb -m 0755 "$A_RUN_ROOT"
rm -f "$A_STATE_FILE" "$A_BACKEND_PID_FILE" "$A_PROBE_STATE_FILE" "$A_PROBE_PID_FILE"

setsid setpriv --reuid="$uid" --regid="$gid" --init-groups \
  python3 "$BACKEND_PROGRAM" \
    --port "$A_BACKEND_PORT" --mode fallback --service "$A_SERVICE" \
    --message "$A_MESSAGE" \
    --context-key "$A_CONTEXT_KEY" --context-value "$A_CONTEXT_VALUE" \
    --header-name "$A_HEADER_NAME" --header-value "$A_HEADER_VALUE" \
    --state-file "$A_STATE_FILE" >"$A_RUN_ROOT/backend.log" 2>&1 < /dev/null &
backend_pid=$!
printf '%s\n' "$backend_pid" >"$A_BACKEND_PID_FILE"
chown agentb:agentb "$A_BACKEND_PID_FILE"

backend_ready=0
for _ in $(seq 1 80); do
  if curl -sS --max-time 1 "http://127.0.0.1:$A_BACKEND_PORT/healthz" >/dev/null 2>&1; then
    backend_ready=1
    break
  fi
  sleep 0.1
done
[ "$backend_ready" = 1 ] || { echo "A_BACKEND_NOT_READY pid=$backend_pid" >&2; exit 1; }

setpriv --reuid="$uid" --regid="$gid" --init-groups nginx -t -p "$GATEWAY_ROOT/" -c conf/nginx.conf
setpriv --reuid="$uid" --regid="$gid" --init-groups nginx -p "$GATEWAY_ROOT/" -c conf/nginx.conf

gateway_ready=0
for _ in $(seq 1 80); do
  if curl -sS --max-time 1 -H "Host: $UNKNOWN_HOST" "http://127.0.0.1:$GATEWAY_PORT/ready-check" >/dev/null 2>&1; then
    gateway_ready=1
    break
  fi
  sleep 0.1
done
[ "$gateway_ready" = 1 ] || { echo "A_GATEWAY_NOT_READY backend=$backend_pid" >&2; exit 1; }

setsid setpriv --reuid="$uid" --regid="$gid" --init-groups \
  python3 "$PROBE_PROGRAM" --url "http://127.0.0.1:$GATEWAY_PORT" \
    --host "$UNKNOWN_HOST" --service "$A_SERVICE" --message "$A_MESSAGE" \
    --path "$A_PROBE_PATH" --context-key "$A_CONTEXT_KEY" --context-value "$A_CONTEXT_VALUE" \
    --header-name "$A_HEADER_NAME" --header-value "$A_HEADER_VALUE" \
    --state-file "$A_PROBE_STATE_FILE" --interval 0.2 \
    >"$A_RUN_ROOT/probe.log" 2>&1 < /dev/null &
probe_pid=$!
printf '%s\n' "$probe_pid" >"$A_PROBE_PID_FILE"
chown agentb:agentb "$A_PROBE_PID_FILE"

a_ready=0
for _ in $(seq 1 100); do
  if CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    a_ready=1
    break
  fi
  sleep 0.1
done
[ "$a_ready" = 1 ] || { echo "A_NOT_READY backend=$backend_pid probe=$probe_pid" >&2; exit 1; }
master_pid=$(cat "$NGINX_PID_FILE")
echo "A_STARTED master_pid=$master_pid backend_pid=$backend_pid probe_pid=$probe_pid listener=127.0.0.1:$GATEWAY_PORT default_server=1"
