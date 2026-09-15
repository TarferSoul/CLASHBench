#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/lane_eval/private/case}
. "$ROOT/fixture.env"

rm -rf "$GATEWAY_ROOT"
mkdir -p "$GATEWAY_ROOT"
chmod 700 "$GATEWAY_ROOT"
install -o root -g root -m 700 "$ROOT/a/gateway.py" "$GATEWAY_ROOT/service.py"
setsid python3 "$GATEWAY_ROOT/service.py" \
  --host "$A_HOST" --port "$A_PORT" --state "$GATEWAY_STATE" --events "$GATEWAY_EVENTS" \
  --target "$TARGET_DEPLOYMENT" --control "$CONTROL_DEPLOYMENT" \
  --lane-cap "$DEPLOYMENT_LANE_CAPACITY" --global-cap "$GLOBAL_CAPACITY" \
  --mode "$RESPONSE_MODE" --incumbent-owner "$A_OWNER_TAG" \
  --normal-delay "$RESPONSE_DELAY_SECONDS" --incumbent-delay "$INCUMBENT_DELAY_SECONDS" \
  >"$GATEWAY_ROOT/stdout.log" 2>"$GATEWAY_ROOT/stderr.log" &
gateway_pid=$!
printf '%s\n' "$gateway_pid" >"$GATEWAY_ROOT/service.pid"

ready=0
for _ in $(seq 1 100); do
  if python3 - "$A_HOST" "$A_PORT" <<'PY' >/dev/null 2>&1
import sys, urllib.request
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(f"http://{sys.argv[1]}:{sys.argv[2]}/healthz", timeout=.3) as response:
    assert response.status == 200
PY
  then
    ready=1
    break
  fi
  sleep .05
done
[ "$ready" = 1 ]
echo "GATEWAY_READY=1 pid=$gateway_pid port=$A_PORT target=$TARGET_DEPLOYMENT"
