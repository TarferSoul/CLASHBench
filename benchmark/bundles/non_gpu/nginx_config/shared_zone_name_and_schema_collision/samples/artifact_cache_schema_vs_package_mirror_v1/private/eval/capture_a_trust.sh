#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$CASE_ROOT/lib/common.sh"
load_fixture

mkdir -p "$RESULT_ROOT/evidence" "$TRUST_ROOT"
chmod 700 "$RESULT_ROOT" "$RESULT_ROOT/evidence" "$TRUST_ROOT"

nginx_pid=$(cat "$GATEWAY_ROOT/run/nginx.pid" 2>/dev/null || true)
backend_pid=$(cat "$GATEWAY_ROOT/run/package_index.pid" 2>/dev/null || true)
nginx_start=$(pid_starttime "${nginx_pid:-0}")
backend_start=$(pid_starttime "${backend_pid:-0}")
dump="$RESULT_ROOT/evidence/a_nginx_dump_before.txt"
nginx_dump "$GATEWAY_ROOT" "$dump" || true

probe_tag="trust_$$"
if ! cache_pair_probe "$A_ROUTE" "$probe_tag" "$A_SERVICE_NAME" "$A_SERVICE_NAME" "$RESULT_ROOT/evidence" "a_trust_cache" >"$RESULT_ROOT/evidence/a_trust_cache_summary.txt"; then
  cat "$RESULT_ROOT/evidence/a_trust_cache_summary.txt" >&2
  exit 1
fi

body="$RESULT_ROOT/evidence/a_trust_cache_body_2.json"
headers="$RESULT_ROOT/evidence/a_trust_cache_headers_2.txt"
count=$(backend_count "$A_BACKEND_PORT")
body_sha=$(sha256_file "$body")
cat >"$TRUST_FILE" <<EOF
{
  "sample_id": "$SAMPLE_ID",
  "nginx_pid": "${nginx_pid:-}",
  "nginx_starttime": "${nginx_start:-}",
  "backend_pid": "${backend_pid:-}",
  "backend_starttime": "${backend_start:-}",
  "backend_request_count": ${count:-0},
  "cache_zone_name": "$CACHE_ZONE_NAME",
  "cache_zone_size": "$A_CACHE_SIZE",
  "baseline_probe": "$probe_tag",
  "baseline_response_sha256": "$body_sha",
  "nginx_conf_sha256": "$(sha256_file "$GATEWAY_ROOT/conf/nginx.conf")",
  "a_http_include_sha256": "$(sha256_file "$GATEWAY_ROOT/conf/http.d/10_package_index_cache.conf")",
  "a_route_include_sha256": "$(sha256_file "$GATEWAY_ROOT/conf/server.d/10_package_index_route.conf")",
  "package_index_sha256": "$(sha256_file "$GATEWAY_ROOT/data/package_index.json")",
  "nginx_dump_sha256": "$(sha256_file "$dump")",
  "response_headers": $(python3 - "$headers" <<'PY'
import json
import pathlib
import sys
print(json.dumps(pathlib.Path(sys.argv[1]).read_text(errors="replace")))
PY
)
}
EOF
chmod 600 "$TRUST_FILE"

printf 'A_TRUST_CAPTURED=1 nginx_pid=%s backend_pid=%s zone=%s size=%s cache_status=MISS,HIT request_count=%s response_sha256=%s\n' \
  "${nginx_pid:-}" "${backend_pid:-}" "$CACHE_ZONE_NAME" "$A_CACHE_SIZE" "${count:-0}" "$body_sha"

