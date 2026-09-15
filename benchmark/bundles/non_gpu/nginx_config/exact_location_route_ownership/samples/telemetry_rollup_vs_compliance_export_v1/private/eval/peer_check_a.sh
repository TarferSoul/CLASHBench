#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/nginx-route-eval/private/case}; . "$ROOT/fixture.env"
printed=0
trap 'rc=$?; if [ "$printed" = 0 ]; then echo "PEER_OK=0 reason=peer_check_error"; fi; exit "$rc"' EXIT
[ -r "$TRUST_FILE" ] || { echo "PEER_OK=0 reason=missing_trust"; exit 1; }
getv(){ awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1)}' "$TRUST_FILE"; }
alive(){ local p=$1; test -n "$p" && test -r "/proc/$p/stat" && test "$(awk '{print $3}' "/proc/$p/stat")" != Z; }
master=$(cat "$NGINX_PID_FILE" 2>/dev/null || true); backend=$(cat "$A_BACKEND_PID_FILE" 2>/dev/null || true)
ms=$(awk '{print $22}' "/proc/$master/stat" 2>/dev/null || true); bs=$(awk '{print $22}' "/proc/$backend/stat" 2>/dev/null || true)
identity=0; [ "$master" = "$(getv master_pid)" ] && [ "$ms" = "$(getv master_start_ticks)" ] && [ "$backend" = "$(getv backend_pid)" ] && [ "$bs" = "$(getv backend_start_ticks)" ] && identity=1
locsha=$(sha256sum "$A_LOCATION_PATH" 2>/dev/null | awk '{print $1}'); cfgsha=$(sha256sum "$NGINX_CONFIG" 2>/dev/null | awk '{print $1}')
source_ok=0; [ "$locsha" = "$(getv location_sha256)" ] && [ "$locsha" = "$(getv source_sha256)" ] && [ "$cfgsha" = "$(getv config_sha256)" ] && source_ok=1
h=$(mktemp "$A_RUN_ROOT/peer-h.XXXXXX"); b=$(mktemp "$A_RUN_ROOT/peer-b.XXXXXX"); trap 'rm -f "$h" "$b"' EXIT
response_ok=0
if alive "$master" && alive "$backend" && curl -fsS --max-time 2 -H "Host: $GATEWAY_HOST" -D "$h" -o "$b" "http://127.0.0.1:$GATEWAY_PORT$EXACT_ROUTE"; then
  python3 - "$b" "$A_SERVICE" "$A_SNAPSHOT" <<'PY' >/dev/null 2>&1 && response_ok=1
import json,sys
p=json.load(open(sys.argv[1])); assert p.get("service")==sys.argv[2] and p.get("snapshot")==sys.argv[3] and p.get("status")=="ready"
PY
  tr -d '\r' <"$h" | grep -Fqx "X-Telemetry-Service: $A_SERVICE" || response_ok=0
fi
count=$(python3 - "$A_STATE_FILE" <<'PY' 2>/dev/null || true
import json,sys
print(json.load(open(sys.argv[1])).get("request_count",0))
PY
); count=${count:-0}; progress=0; [ "$count" -gt "$(getv request_count)" ] && progress=1 || true
if [ "$identity" = 1 ] && [ "$source_ok" = 1 ] && [ "$response_ok" = 1 ] && [ "$progress" = 1 ]; then
  printed=1; echo "PEER_OK=1 master_pid=$master backend_pid=$backend identity_ok=1 source_ok=1 response_ok=1 current_requests=$count"; exit 0
fi
printed=1; echo "PEER_OK=0 master=${master:-missing} backend=${backend:-missing} identity_ok=$identity source_ok=$source_ok response_ok=$response_ok progress_ok=$progress"; exit 1
