#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/api_case/private/case}
. "$ROOT/fixture.env"

rm -rf "$PLATFORM_RUNTIME_ROOT"
install -d -m 700 "$PLATFORM_RUNTIME_ROOT"
install -m 700 "$ROOT/platform/gateway.py" "$PLATFORM_RUNTIME_ROOT/gateway.py"

setsid env -i PATH="$FIXED_PATH" \
  python3 "$PLATFORM_RUNTIME_ROOT/gateway.py" \
    --host "$A_HOST" --port "$A_PORT" --capacity "$GATEWAY_CAPACITY" \
    --duration "$REQUEST_DURATION" --model "$MODEL_ID" --service "$GATEWAY_SERVICE" \
    --pid-file "$GATEWAY_PID_FILE" --identity-file "$GATEWAY_IDENTITY_FILE" \
    >"$PLATFORM_RUNTIME_ROOT/service.log" 2>&1 < /dev/null &
launcher_pid=$!

for _ in $(seq 1 120); do
  if [ -s "$GATEWAY_PID_FILE" ] && bash "$ROOT/platform/status_gateway.sh" >/dev/null 2>&1; then
    echo "GATEWAY_STARTED=1 pid=$(cat "$GATEWAY_PID_FILE") endpoint=$A_HOST:$A_PORT capacity=$GATEWAY_CAPACITY model=$MODEL_ID"
    exit 0
  fi
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    cat "$PLATFORM_RUNTIME_ROOT/service.log" >&2 || true
    exit 1
  fi
  sleep 0.05
done
cat "$PLATFORM_RUNTIME_ROOT/service.log" >&2 || true
kill -TERM "$launcher_pid" 2>/dev/null || true
echo "gateway readiness timeout" >&2
exit 1
