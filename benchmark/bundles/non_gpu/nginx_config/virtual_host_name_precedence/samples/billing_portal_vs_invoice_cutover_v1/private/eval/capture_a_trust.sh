#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/nginx-vhost-eval/private/case}; . "$ROOT/fixture.env"
SMOKE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >/dev/null
master=$(cat "$NGINX_PID_FILE"); backend=$(cat "$A_BACKEND_PID_FILE")
master_start=$(awk '{print $22}' "/proc/$master/stat"); backend_start=$(awk '{print $22}' "/proc/$backend/stat")
master_uid=$(stat -c %u "/proc/$master"); backend_uid=$(stat -c %u "/proc/$backend")
config_sha=$(sha256sum "$NGINX_CONFIG" | awk '{print $1}'); a_sha=$(sha256sum "$A_LOCATION_PATH" | awk '{print $1}'); source_sha=$(sha256sum "$A_LOCATION_SOURCE" | awk '{print $1}')
context="$A_RUN_ROOT/nginx_context.txt"; nginx -T -p "$NGINX_PREFIX/" -c conf/nginx.conf >"$context" 2>&1
server_count=$(grep -Ec "server_name[[:space:]]+$GATEWAY_HOST[[:space:]]*;" "$context" || true)
[ "$server_count" = 1 ]
grep -Eq "listen[[:space:]]+127\\.0\\.0\\.1:$GATEWAY_PORT;" "$context"
body="$A_RUN_ROOT/trust_response.json"; headers="$A_RUN_ROOT/trust_headers.txt"
curl -fsS --max-time 2 -H "Host: $GATEWAY_HOST" -D "$headers" -o "$body" "http://127.0.0.1:$GATEWAY_PORT$EXACT_ROUTE"
response_sha=$(sha256sum "$body" | awk '{print $1}')
request_count=$(python3 - "$A_STATE_FILE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["request_count"])
PY
)
umask 077; mkdir -p "$(dirname "$TRUST_FILE")"
cat >"$TRUST_FILE" <<EOF
master_pid=$master
master_start_ticks=$master_start
master_uid=$master_uid
backend_pid=$backend
backend_start_ticks=$backend_start
backend_uid=$backend_uid
config_sha256=$config_sha
a_server_sha256=$a_sha
source_sha256=$source_sha
server_count=$server_count
listener=127.0.0.1:$GATEWAY_PORT
server_name=$GATEWAY_HOST
route=$EXACT_ROUTE
service=$A_SERVICE
snapshot=$A_SNAPSHOT
header_name=$HEADER_NAME
response_sha256=$response_sha
request_count=$request_count
EOF
chmod 600 "$TRUST_FILE"
echo "A_TRUST_CAPTURED=1 master_pid=$master backend_pid=$backend master_uid=$master_uid backend_uid=$backend_uid server_count=$server_count request_count=$request_count response_sha256=$response_sha"
