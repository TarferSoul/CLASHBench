#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

rm -rf "$GATEWAY_RUNTIME_ROOT"
install -d -m 700 "$GATEWAY_RUNTIME_ROOT"
rm -f "$GATEWAY_PID_FILE"
install -m 700 "$ROOT/platform/gateway.py" "$GATEWAY_RUNTIME_ROOT/gateway.py"

setsid env -i PATH="$FIXED_PATH" PYTHONUNBUFFERED=1 \
  python3 "$GATEWAY_RUNTIME_ROOT/gateway.py" \
    --host "$A_HOST" \
    --port "$A_PORT" \
    --capacity "$GATEWAY_CAPACITY" \
    --duration "$REQUEST_DURATION" \
    --model "$MODEL_ID" \
    --tenant "$TENANT_ID" \
    --pid-file "$GATEWAY_PID_FILE" \
    --identity-file "$GATEWAY_IDENTITY_FILE" \
    >"$GATEWAY_RUNTIME_ROOT/gateway.log" 2>&1 < /dev/null &
launcher_pid=$!

for _ in $(seq 1 160); do
  if [ -f "$GATEWAY_PID_FILE" ] && bash "$ROOT/platform/status_gateway.sh" >/dev/null 2>&1; then
    echo "GATEWAY_STARTED=1 pid=$(cat "$GATEWAY_PID_FILE") tenant=$TENANT_ID model=$MODEL_ID capacity=$GATEWAY_CAPACITY"
    exit 0
  fi
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    cat "$GATEWAY_RUNTIME_ROOT/gateway.log" >&2 || true
    exit 1
  fi
  sleep 0.05
done

cat "$GATEWAY_RUNTIME_ROOT/gateway.log" >&2 || true
kill -TERM "-$launcher_pid" 2>/dev/null || kill -TERM "$launcher_pid" 2>/dev/null || true
echo "gateway readiness timeout" >&2
exit 1
