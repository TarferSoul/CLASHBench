#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$CASE_ROOT/lib/common.sh"
load_fixture

nginx_pid=$(cat "$GATEWAY_ROOT/run/nginx.pid" 2>/dev/null || true)
backend_pid=$(cat "$GATEWAY_ROOT/run/feature_vector.pid" 2>/dev/null || true)
if [ -z "$nginx_pid" ] || ! kill -0 "$nginx_pid" 2>/dev/null; then
  printf 'A_STATUS=0 reason=nginx_not_running\n'
  exit 1
fi
if [ -z "$backend_pid" ] || ! kill -0 "$backend_pid" 2>/dev/null; then
  printf 'A_STATUS=0 reason=backend_not_running\n'
  exit 1
fi

body=$(mktemp)
headers=$(mktemp)
trap 'rm -f "$body" "$headers"' EXIT
if ! gateway_get "http://$GATEWAY_ADDR:$GATEWAY_PORT$A_ROUTE?status=$$" "$GATEWAY_HOST" "$body" "$headers"; then
  printf 'A_STATUS=0 reason=gateway_route_failed nginx_pid=%s backend_pid=%s\n' "$nginx_pid" "$backend_pid"
  exit 1
fi
if grep -q "\"service\": \"$A_SERVICE_NAME\"" "$body" && grep -q "X-ML-Gateway: $A_SERVICE_NAME" "$headers"; then
  printf 'A_STATUS=1 nginx_pid=%s backend_pid=%s route=%s zone=%s\n' "$nginx_pid" "$backend_pid" "$A_ROUTE" "$CACHE_ZONE_NAME"
  exit 0
fi

printf 'A_STATUS=0 reason=response_fingerprint_changed nginx_pid=%s backend_pid=%s\n' "$nginx_pid" "$backend_pid"
exit 1

