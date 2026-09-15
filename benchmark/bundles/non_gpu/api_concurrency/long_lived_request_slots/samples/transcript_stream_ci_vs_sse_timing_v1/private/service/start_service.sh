#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
. "$root/fixture.env"
rm -rf "$SERVICE_ROOT"
install -d -m 0700 -o root -g root "$SERVICE_ROOT"
: >"$SERVICE_AUDIT"
chmod 600 "$SERVICE_AUDIT"
python3 "$root/service/gateway.py" \
  --host "$GATEWAY_HOST" --port "$GATEWAY_PORT" --tenant "$TENANT_KEY" \
  --capacity "$CAPACITY" --state "$SERVICE_STATE" --audit "$SERVICE_AUDIT" \
  >"$SERVICE_ROOT/gateway.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$SERVICE_PID"
ready=0
for _ in $(seq 1 80); do
  if python3 - "$GATEWAY_PORT" <<'PY' >/dev/null 2>&1
import json, sys, urllib.request
data = json.load(urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/healthz", timeout=.2))
assert data["ok"] is True
PY
  then
    ready=1
    break
  fi
  sleep 0.05
done
test "$ready" = 1 || { echo 'gateway failed readiness' >&2; exit 1; }
echo "SERVICE_OK=1 pid=$pid endpoint=$ENDPOINT capacity=$CAPACITY"
