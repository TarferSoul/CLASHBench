#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

mkdir -p "$GATEWAY_RUNTIME_ROOT" "$(dirname "$GATEWAY_PID_FILE")"
chmod 700 "$GATEWAY_RUNTIME_ROOT"
if [ -s "$GATEWAY_PID_FILE" ] && kill -0 "$(cat "$GATEWAY_PID_FILE")" 2>/dev/null; then
  echo "GATEWAY_ALREADY_RUNNING pid=$(cat "$GATEWAY_PID_FILE")"
  exit 0
fi
rm -f "$GATEWAY_PID_FILE" "$GATEWAY_IDENTITY_FILE"
python3 "$ROOT/platform/model_gateway.py" \
  --host "$A_HOST" \
  --port "$A_PORT" \
  --capacity "$GATEWAY_CAPACITY" \
  --duration "$REQUEST_DURATION" \
  --deployment "$MODEL_ID" \
  --tenant "$TENANT_ID" \
  --pid-file "$GATEWAY_PID_FILE" \
  --identity-file "$GATEWAY_IDENTITY_FILE" \
  >"$GATEWAY_RUNTIME_ROOT/service.stdout" 2>"$GATEWAY_RUNTIME_ROOT/service.stderr" &
pid=$!

ready=0
for _ in $(seq 1 80); do
  if python3 - "$A_HOST" "$A_PORT" >/dev/null 2>&1 <<'PY'
import sys
import urllib.request
host, port = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=0.3) as response:
    raise SystemExit(0 if response.status == 200 else 1)
PY
  then
    ready=1
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if [ "$ready" != 1 ]; then
  echo "GATEWAY_START_FAILED pid=$pid" >&2
  cat "$GATEWAY_RUNTIME_ROOT/service.stderr" >&2 || true
  exit 1
fi
echo "GATEWAY_READY=1 pid=$pid tenant=$TENANT_ID deployment=$MODEL_ID capacity=$GATEWAY_CAPACITY"
