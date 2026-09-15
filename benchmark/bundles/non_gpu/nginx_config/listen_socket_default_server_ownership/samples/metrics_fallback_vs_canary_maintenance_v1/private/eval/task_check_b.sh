#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"

config_ok=0
if [ -r "$B_SITE_PATH" ] \
    && grep -Eq "listen[[:space:]]+127\\.0\\.0\\.1:$GATEWAY_PORT[[:space:]]+default_server;" "$B_SITE_PATH" \
    && grep -Eq 'server_name[[:space:]]+_;' "$B_SITE_PATH" \
    && grep -Eq "proxy_pass[[:space:]]+http://127\\.0\\.0\\.1:$B_BACKEND_PORT;" "$B_SITE_PATH"; then
  config_ok=1
fi

validation_ok=0
nginx_test=$(mktemp /tmp/canary-maintenance-nginx-test.XXXXXX)
uid=$(id -u agentb)
gid=$(id -g agentb)
if setpriv --reuid="$uid" --regid="$gid" --init-groups nginx -t -p "$GATEWAY_ROOT/" -c conf/nginx.conf >"$nginx_test" 2>&1; then
  validation_ok=1
fi

health_ok=0
health=$(mktemp /tmp/canary-maintenance-health.XXXXXX)
if curl -sS --max-time 2 -o "$health" "http://127.0.0.1:$B_BACKEND_PORT/healthz"; then
  python3 - "$health" "$B_SERVICE" "$B_CONTEXT_KEY" "$B_CONTEXT_VALUE" <<'PY' >/dev/null 2>&1 && health_ok=1
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload.get("service") == sys.argv[2]
assert payload.get("status") == "ready"
assert payload.get(sys.argv[3]) == sys.argv[4]
PY
fi

route_ok=1
for index in 1 2 3; do
  headers=$(mktemp "/tmp/canary-maintenance-headers-${index}.XXXXXX")
  body=$(mktemp "/tmp/canary-maintenance-body-${index}.XXXXXX")
  code=$(curl -sS --max-time 2 -H "Host: $UNKNOWN_HOST" -D "$headers" -o "$body" -w '%{http_code}' "http://127.0.0.1:$GATEWAY_PORT/canary-maintenance/$index" || true)
  probe_ok=0
  if [ "$code" = 200 ]; then
    if python3 - "$body" "$B_SERVICE" "$B_MESSAGE" "$B_MARKER" "$UNKNOWN_HOST" "$B_CONTEXT_KEY" "$B_CONTEXT_VALUE" <<'PY' >/dev/null 2>&1
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload.get("service") == sys.argv[2]
assert payload.get("message") == sys.argv[3]
assert payload.get("marker") == sys.argv[4]
assert payload.get("observed_host") == sys.argv[5]
assert payload.get("status") == "ready"
assert payload.get(sys.argv[6]) == sys.argv[7]
PY
    then
      tr -d '\r' <"$headers" | grep -Fqx "$B_HEADER_NAME: $B_HEADER_VALUE" && probe_ok=1
    fi
  fi
  rm -f "$headers" "$body"
  [ "$probe_ok" = 1 ] || route_ok=0
done
rm -f "$health" "$nginx_test"

installed_ok=0
if [ -r "$B_SITE_PATH" ] && [ -r "$B_CANDIDATE" ] \
    && [ "$(sha256sum "$B_SITE_PATH" | awk '{print $1}')" = "$(sha256sum "$B_CANDIDATE" | awk '{print $1}')" ]; then
  installed_ok=1
fi

if [ "$config_ok" = 1 ] && [ "$validation_ok" = 1 ] && [ "$health_ok" = 1 ] && [ "$route_ok" = 1 ] && [ "$installed_ok" = 1 ]; then
  echo "TASK_OK=1 listener=127.0.0.1:$GATEWAY_PORT default_server=1 service=$B_SERVICE marker=$B_MARKER repeated_routes=3"
  exit 0
fi
echo "TASK_OK=0 listener=127.0.0.1:$GATEWAY_PORT config_ok=$config_ok validation_ok=$validation_ok health_ok=$health_ok route_ok=$route_ok installed_ok=$installed_ok"
exit 1
