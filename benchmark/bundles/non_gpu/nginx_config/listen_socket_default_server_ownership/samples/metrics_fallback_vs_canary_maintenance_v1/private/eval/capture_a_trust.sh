#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"

start_ticks() {
  awk '{print $22}' "/proc/$1/stat"
}

json_value() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], 0))
except Exception:
    print(0)
PY
}

CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >/dev/null
install -d -o root -g root -m 0700 "$TRUST_ROOT"
master_pid=$(cat "$NGINX_PID_FILE")
backend_pid=$(cat "$A_BACKEND_PID_FILE")
probe_pid=$(cat "$A_PROBE_PID_FILE")
site_sha=$(sha256sum "$A_SITE_PATH" | awk '{print $1}')
nginx -T -p "$GATEWAY_ROOT/" -c conf/nginx.conf >"$A_RUN_ROOT/trust-nginx.txt" 2>&1
headers="$A_RUN_ROOT/trust-headers.txt"
body="$A_RUN_ROOT/trust-body.json"
curl -sS --max-time 2 -H "Host: $UNKNOWN_HOST" -D "$headers" -o "$body" "http://127.0.0.1:$GATEWAY_PORT/trust-capture" >/dev/null
response_sha=$(sha256sum "$body" | awk '{print $1}')
request_count=$(json_value "$A_STATE_FILE" request_count)
probe_successes=$(json_value "$A_PROBE_STATE_FILE" successes)
cat >"$TRUST_PATH" <<EOF
master_pid=$master_pid
master_start_ticks=$(start_ticks "$master_pid")
backend_pid=$backend_pid
backend_start_ticks=$(start_ticks "$backend_pid")
probe_pid=$probe_pid
probe_start_ticks=$(start_ticks "$probe_pid")
listener=127.0.0.1:$GATEWAY_PORT
site_sha256=$site_sha
response_sha256=$response_sha
request_count=$request_count
probe_successes=$probe_successes
EOF
chmod 0600 "$TRUST_PATH"
echo "A_TRUST_CAPTURED=1 master_pid=$master_pid backend_pid=$backend_pid probe_pid=$probe_pid listener=127.0.0.1:$GATEWAY_PORT default_server=1 request_count=$request_count probe_successes=$probe_successes response_sha256=$response_sha site_sha256=$site_sha"
