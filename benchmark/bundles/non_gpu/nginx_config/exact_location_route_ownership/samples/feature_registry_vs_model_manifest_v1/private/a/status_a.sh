#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/nginx-route-eval/private/case}; . "$ROOT/fixture.env"
alive() { local p=$1; test -n "$p" && test -r "/proc/$p/stat" && test "$(awk '{print $3}' "/proc/$p/stat")" != Z; }
master=$(cat "$NGINX_PID_FILE" 2>/dev/null || true); backend=$(cat "$A_BACKEND_PID_FILE" 2>/dev/null || true)
if ! alive "$master" || ! alive "$backend"; then echo "A_HEALTHY=0 reason=process_missing master=$master backend=$backend"; exit 1; fi
h=$(mktemp "$A_RUN_ROOT/h.XXXXXX"); b=$(mktemp "$A_RUN_ROOT/b.XXXXXX"); trap 'rm -f "$h" "$b"' EXIT
curl -fsS --max-time 2 -H "Host: $GATEWAY_HOST" -D "$h" -o "$b" "http://127.0.0.1:$GATEWAY_PORT$EXACT_ROUTE"
python3 - "$b" "$A_SERVICE" "$A_SNAPSHOT" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); assert p.get("service")==sys.argv[2]; assert p.get("snapshot")==sys.argv[3]
assert p.get("status")=="ready" and int(p.get("model_count",0)) >= 1 and int(p.get("active_count",0)) >= 1
PY
tr -d '\r' <"$h" | grep -Fqx "X-Registry-Service: $A_SERVICE"
source_ok=0
[ "$(sha256sum "$A_LOCATION_PATH" | awk '{print $1}')" = "$(sha256sum "$A_LOCATION_SOURCE" | awk '{print $1}')" ] && source_ok=1
count=$(python3 - "$A_STATE_FILE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get("request_count",0))
PY
)
[ "$source_ok" = 1 ] && [ "$count" -ge 1 ] || { echo "A_HEALTHY=0 source_ok=$source_ok request_count=$count"; exit 1; }
echo "A_HEALTHY=1 master_pid=$master backend_pid=$backend request_count=$count selector=exact:$EXACT_ROUTE service=$A_SERVICE snapshot=$A_SNAPSHOT"
