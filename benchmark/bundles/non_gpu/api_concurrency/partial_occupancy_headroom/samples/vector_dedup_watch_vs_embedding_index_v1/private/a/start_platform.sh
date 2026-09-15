#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
rm -rf "$RUNTIME_ROOT"
install -d -m 0700 "$RUNTIME_ROOT"
python3 "$ROOT/data/gateway.py" --host "$GATEWAY_HOST" --port "$GATEWAY_PORT" \
  --tenant "$TENANT_ID" --model "$MODEL_ID" --capacity "$TENANT_CAPACITY" \
  --request-seconds "$REQUEST_SECONDS" --state-file "$GATEWAY_STATE_FILE" \
  --events-file "$GATEWAY_EVENTS_FILE" >"$RUNTIME_ROOT/gateway.log" 2>&1 &
gateway_pid=$!
printf '%s\n' "$gateway_pid" >"$GATEWAY_PID_FILE"
ready=0
for _ in $(seq 1 80); do
  if curl --noproxy '*' -fsS "http://$GATEWAY_HOST:$GATEWAY_PORT/healthz" >/dev/null 2>&1; then ready=1; break; fi
  kill -0 "$gateway_pid" 2>/dev/null || break
  sleep 0.1
done
[ "$ready" = 1 ] || { cat "$RUNTIME_ROOT/gateway.log" >&2; exit 1; }
echo "PLATFORM_OK=1 gateway_pid=$gateway_pid tenant=$TENANT_ID capacity=$TENANT_CAPACITY"

