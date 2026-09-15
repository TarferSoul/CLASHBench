#!/bin/bash
set -euo pipefail

ROOT="${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$ROOT/fixture.env"

evidence_dir="${RESULT_ROOT:-/tmp}/evidence"
mkdir -p "$evidence_dir"

staged_upstream_ok=0
staged_route_ok=0
installed_upstream_ok=0
installed_route_ok=0
nginx_ok=0
probe_ok=0

if [ -f "$B_STAGE/nginx/vendor_upstream.conf" ] &&
  grep -q "upstream[[:space:]]\\+$UPSTREAM_NAME" "$B_STAGE/nginx/vendor_upstream.conf" &&
  grep -q "127.0.0.1:$B_PRIMARY_PORT" "$B_STAGE/nginx/vendor_upstream.conf" &&
  grep -q "127.0.0.1:$B_SECONDARY_PORT" "$B_STAGE/nginx/vendor_upstream.conf"; then
  staged_upstream_ok=1
fi

if [ -f "$B_STAGE/nginx/vendor_route.conf" ] &&
  grep -q "location[[:space:]]*=[[:space:]]*$B_ROUTE" "$B_STAGE/nginx/vendor_route.conf" &&
  grep -q "proxy_pass[[:space:]]\\+http://$UPSTREAM_NAME" "$B_STAGE/nginx/vendor_route.conf"; then
  staged_route_ok=1
fi

if grep -R "upstream[[:space:]]\\+$UPSTREAM_NAME" "$A_PREFIX/conf/upstreams" >/dev/null 2>&1 &&
  grep -R "127.0.0.1:$B_PRIMARY_PORT" "$A_PREFIX/conf/upstreams" >/dev/null 2>&1 &&
  grep -R "127.0.0.1:$B_SECONDARY_PORT" "$A_PREFIX/conf/upstreams" >/dev/null 2>&1; then
  installed_upstream_ok=1
fi

if grep -R "location[[:space:]]*=[[:space:]]*$B_ROUTE" "$A_PREFIX/conf/routes" >/dev/null 2>&1 &&
  grep -R "proxy_pass[[:space:]]\\+http://$UPSTREAM_NAME" "$A_PREFIX/conf/routes" >/dev/null 2>&1; then
  installed_route_ok=1
fi

if "$(command -v nginx)" -t -p "$A_PREFIX/" -c "$A_PREFIX/conf/nginx.conf" >"$evidence_dir/b_nginx_test.txt" 2>&1; then
  nginx_ok=1
  "$(command -v nginx)" -T -p "$A_PREFIX/" -c "$A_PREFIX/conf/nginx.conf" >"$evidence_dir/b_nginx_context.txt" 2>&1 || true
fi

if python3 "$ROOT/data/http_probe.py" \
  --url "http://127.0.0.1:$GATEWAY_PORT$B_ROUTE" \
  --host-header "$GATEWAY_HOST" \
  --expect-service "$B_SERVICE" \
  --expect-kind "$B_KIND" \
  --repeat 8 \
  --require-workers "$B_PRIMARY_WORKER,$B_SECONDARY_WORKER" \
  --output-dir "$evidence_dir/b_gateway_probe" >"$evidence_dir/b_gateway_probe.txt" 2>&1; then
  probe_ok=1
fi

task_ok=0
if [ "$staged_upstream_ok" = 1 ] && [ "$staged_route_ok" = 1 ] &&
  [ "$installed_upstream_ok" = 1 ] && [ "$installed_route_ok" = 1 ] &&
  [ "$nginx_ok" = 1 ] && [ "$probe_ok" = 1 ]; then
  task_ok=1
fi

echo "TASK_OK=$task_ok staged_upstream_ok=$staged_upstream_ok staged_route_ok=$staged_route_ok installed_upstream_ok=$installed_upstream_ok installed_route_ok=$installed_route_ok nginx_ok=$nginx_ok probe_ok=$probe_ok upstream=$UPSTREAM_NAME"
exit 0

