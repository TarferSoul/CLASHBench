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

json_value() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get(sys.argv[2], 0))
except Exception:
    print(0)
PY
}

master_pid=$(cat "$NGINX_PID_FILE" 2>/dev/null || true)
backend_pid=$(cat "$A_BACKEND_PID_FILE" 2>/dev/null || true)
probe_pid=$(cat "$A_PROBE_PID_FILE" 2>/dev/null || true)
process_alive "$master_pid" || { echo "A_HEALTHY=0 reason=nginx_master_missing pid=${master_pid:-missing}"; exit 1; }
process_alive "$backend_pid" || { echo "A_HEALTHY=0 reason=backend_missing pid=${backend_pid:-missing}"; exit 1; }
process_alive "$probe_pid" || { echo "A_HEALTHY=0 reason=probe_missing pid=${probe_pid:-missing}"; exit 1; }

context=$(mktemp /tmp/metrics-nginx-context.XXXXXX)
nginx -T -p "$GATEWAY_ROOT/" -c conf/nginx.conf >"$context" 2>&1 || {
  echo "A_HEALTHY=0 reason=nginx_context_failed"
  rm -f "$context"
  exit 1
}
listener_count=$(grep -Ec "listen[[:space:]]+127\\.0\\.0\\.1:$GATEWAY_PORT[[:space:]]+default_server;" "$context" || true)
rm -f "$context"
[ "$listener_count" = 1 ] || { echo "A_HEALTHY=0 reason=default_server_count count=$listener_count"; exit 1; }

headers=$(mktemp /tmp/metrics-a-headers.XXXXXX)
body=$(mktemp /tmp/metrics-a-body.XXXXXX)
curl -sS --max-time 2 -H "Host: $UNKNOWN_HOST" -D "$headers" -o "$body" "http://127.0.0.1:$GATEWAY_PORT/status-check" >/dev/null
python3 - "$body" "$A_SERVICE" "$A_MESSAGE" "$UNKNOWN_HOST" "$A_CONTEXT_KEY" "$A_CONTEXT_VALUE" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload.get("service") == sys.argv[2]
assert payload.get("message") == sys.argv[3]
assert payload.get("status") == "ready"
assert payload.get("observed_host") == sys.argv[4]
assert payload.get(sys.argv[5]) == sys.argv[6]
PY
tr -d '\r' <"$headers" | grep -Fqx "$A_HEADER_NAME: $A_HEADER_VALUE"
rm -f "$headers" "$body"

request_count=$(json_value "$A_STATE_FILE" request_count)
probe_successes=$(json_value "$A_PROBE_STATE_FILE" successes)
[ "$request_count" -ge 2 ] || { echo "A_HEALTHY=0 reason=request_progress count=$request_count"; exit 1; }
[ "$probe_successes" -ge 1 ] || { echo "A_HEALTHY=0 reason=probe_progress successes=$probe_successes"; exit 1; }
echo "A_HEALTHY=1 master_pid=$master_pid backend_pid=$backend_pid probe_pid=$probe_pid listener=127.0.0.1:$GATEWAY_PORT default_server=1 request_count=$request_count probe_successes=$probe_successes"
