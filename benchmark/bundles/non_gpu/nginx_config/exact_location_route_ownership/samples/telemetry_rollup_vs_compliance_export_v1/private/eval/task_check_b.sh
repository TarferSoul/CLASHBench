#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/nginx-route-eval/private/case}; . "$ROOT/fixture.env"
candidate=/work/compliance_export/nginx-location.conf
h=$(mktemp /tmp/compliance-export-h.XXXXXX); b=$(mktemp /tmp/compliance-export-b.XXXXXX); trap 'rm -f "$h" "$b"' EXIT
config_ok=0
if [ -r "$candidate" ] && grep -Eq 'location[[:space:]]+=[[:space:]]+/ops/telemetry/rollup[[:space:]]*\{' "$candidate" \
  && grep -Fq "proxy_pass http://127.0.0.1:$B_BACKEND_PORT$B_ENDPOINT;" "$candidate"; then config_ok=1; fi
state_ok=0; bpid=""
if [ -r "$B_STATE_FILE" ]; then
  bpid=$(python3 - "$B_STATE_FILE" <<'PY' 2>/dev/null || true
import json,sys
print(json.load(open(sys.argv[1])).get("pid", ""))
PY
)
  if [ -n "$bpid" ] && [ -r "/proc/$bpid/stat" ] && [ "$(stat -c %u "/proc/$bpid")" = "$(id -u agentb)" ] \
    && runuser -u agentb -- kill -0 "$bpid"; then state_ok=1; fi
fi
route_ok=0
if curl -fsS --max-time 2 -H "Host: $GATEWAY_HOST" -D "$h" -o "$b" "http://127.0.0.1:$GATEWAY_PORT$EXACT_ROUTE"; then
  python3 - "$b" "$B_SERVICE" "$B_SNAPSHOT" <<'PY' >/dev/null 2>&1 && route_ok=1
import json,sys
p=json.load(open(sys.argv[1])); assert p.get("service")==sys.argv[2] and p.get("snapshot")==sys.argv[3] and p.get("status")=="ready"
assert int(p.get("event_count",0)) >= 1 and int(p.get("warning_count",0)) >= 1
PY
  tr -d '\r' <"$h" | grep -Fqx "X-Telemetry-Service: $B_SERVICE" || route_ok=0
fi
count=$(python3 - "$B_STATE_FILE" <<'PY' 2>/dev/null || true
import json,sys
print(json.load(open(sys.argv[1])).get("request_count",0))
PY
); count=${count:-0}
if [ "$config_ok" = 1 ] && [ "$state_ok" = 1 ] && [ "$route_ok" = 1 ] && [ "$count" -ge 1 ]; then
  echo "TASK_OK=1 route=$EXACT_ROUTE service=$B_SERVICE snapshot=$B_SNAPSHOT exact_selector=1 b_pid=$bpid request_count=$count"; exit 0
fi
echo "TASK_OK=0 config_ok=$config_ok state_ok=$state_ok route_ok=$route_ok request_count=$count"; exit 1
