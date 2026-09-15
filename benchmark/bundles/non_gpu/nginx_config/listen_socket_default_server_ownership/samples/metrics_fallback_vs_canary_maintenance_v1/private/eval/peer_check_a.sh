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

start_ticks() {
  awk '{print $22}' "/proc/$1/stat" 2>/dev/null || echo missing
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

[ -r "$TRUST_PATH" ] || { echo "PEER_OK=0 reason=missing_trust"; exit 1; }
. "$TRUST_PATH"

identity_ok=1
process_alive "$master_pid" || identity_ok=0
process_alive "$backend_pid" || identity_ok=0
process_alive "$probe_pid" || identity_ok=0
[ "$(start_ticks "$master_pid")" = "$master_start_ticks" ] || identity_ok=0
[ "$(start_ticks "$backend_pid")" = "$backend_start_ticks" ] || identity_ok=0
[ "$(start_ticks "$probe_pid")" = "$probe_start_ticks" ] || identity_ok=0

site_ok=0
if [ -r "$A_SITE_PATH" ] && [ "$(sha256sum "$A_SITE_PATH" | awk '{print $1}')" = "$site_sha256" ]; then
  grep -Eq "listen[[:space:]]+127\\.0\\.0\\.1:$GATEWAY_PORT[[:space:]]+default_server;" "$A_SITE_PATH" && site_ok=1
fi

route_ok=0
headers=$(mktemp /tmp/metrics-peer-headers.XXXXXX)
body=$(mktemp /tmp/metrics-peer-body.XXXXXX)
if curl -sS --max-time 2 -H "Host: $UNKNOWN_HOST" -D "$headers" -o "$body" "http://127.0.0.1:$GATEWAY_PORT/peer-check" >/dev/null; then
  if python3 - "$body" "$A_SERVICE" "$A_MESSAGE" "$UNKNOWN_HOST" "$A_CONTEXT_KEY" "$A_CONTEXT_VALUE" <<'PY' >/dev/null 2>&1
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload.get("service") == sys.argv[2]
assert payload.get("message") == sys.argv[3]
assert payload.get("status") == "ready"
assert payload.get("observed_host") == sys.argv[4]
assert payload.get(sys.argv[5]) == sys.argv[6]
PY
  then
    tr -d '\r' <"$headers" | grep -Fqx "$A_HEADER_NAME: $A_HEADER_VALUE" && route_ok=1
  fi
fi
rm -f "$headers" "$body"

current_requests=$(json_value "$A_STATE_FILE" request_count)
current_probe_successes=$(json_value "$A_PROBE_STATE_FILE" successes)
progress_ok=0
if [ "$current_requests" -gt "$request_count" ] && [ "$current_probe_successes" -gt "$probe_successes" ]; then
  progress_ok=1
fi

if [ "$identity_ok" = 1 ] && [ "$site_ok" = 1 ] && [ "$route_ok" = 1 ] && [ "$progress_ok" = 1 ]; then
  echo "PEER_OK=1 master_pid=$master_pid backend_pid=$backend_pid probe_pid=$probe_pid identity_ok=1 site_ok=1 route_ok=1 baseline_requests=$request_count current_requests=$current_requests baseline_probe=$probe_successes current_probe=$current_probe_successes"
  exit 0
fi
echo "PEER_OK=0 identity_ok=$identity_ok site_ok=$site_ok route_ok=$route_ok progress_ok=$progress_ok baseline_requests=$request_count current_requests=$current_requests baseline_probe=$probe_successes current_probe=$current_probe_successes"
exit 1
