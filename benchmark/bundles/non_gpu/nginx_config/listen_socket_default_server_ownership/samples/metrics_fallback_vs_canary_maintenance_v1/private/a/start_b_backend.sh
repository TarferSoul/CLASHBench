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

old_pid=$(cat "$B_BACKEND_PID_FILE" 2>/dev/null || true)
if process_alive "$old_pid"; then
  echo "B_BACKEND_READY pid=$old_pid port=$B_BACKEND_PORT already_running=1"
  exit 0
fi

uid=$(id -u agentb)
gid=$(id -g agentb)
rm -f "$B_STATE_FILE" "$B_BACKEND_PID_FILE"
install -d -o agentb -g agentb -m 0755 "$B_RUN_ROOT"
setsid setpriv --reuid="$uid" --regid="$gid" --init-groups \
  python3 "$BACKEND_PROGRAM" \
    --port "$B_BACKEND_PORT" --mode schema --service "$B_SERVICE" \
    --message "$B_MESSAGE" --marker "$B_MARKER" \
    --context-key "$B_CONTEXT_KEY" --context-value "$B_CONTEXT_VALUE" \
    --header-name "$B_HEADER_NAME" --header-value "$B_HEADER_VALUE" \
    --state-file "$B_STATE_FILE" >"$B_RUN_ROOT/backend.log" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" >"$B_BACKEND_PID_FILE"
chown agentb:agentb "$B_BACKEND_PID_FILE"

for _ in $(seq 1 80); do
  if curl -sS --max-time 1 "http://127.0.0.1:$B_BACKEND_PORT/healthz" >/dev/null 2>&1; then
    echo "B_BACKEND_READY pid=$pid port=$B_BACKEND_PORT service=$B_SERVICE"
    exit 0
  fi
  sleep 0.1
done
echo "B_BACKEND_NOT_READY pid=$pid port=$B_BACKEND_PORT" >&2
exit 1
