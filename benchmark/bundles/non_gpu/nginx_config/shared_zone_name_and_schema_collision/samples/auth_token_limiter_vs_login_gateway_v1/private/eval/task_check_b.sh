#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$CASE_ROOT/lib/common.sh"
load_fixture
task_dir="$RESULT_ROOT/evidence/task_$$"; mkdir -p "$task_dir"; chmod 700 "$task_dir"
body1="$task_dir/b_body_1.json"; headers1="$task_dir/b_headers_1.txt"
body2="$task_dir/b_body_2.json"; headers2="$task_dir/b_headers_2.txt"
set +e
gateway_get "http://$GATEWAY_ADDR:$GATEWAY_PORT$B_ROUTE?grade=$$" "$GATEWAY_HOST" "$body1" "$headers1"; rc1=$?
gateway_get "http://$GATEWAY_ADDR:$GATEWAY_PORT$B_ROUTE?grade=$$" "$GATEWAY_HOST" "$body2" "$headers2"; rc2=$?
set -e
status1=$(header_value X-Cache-Status "$headers1" || true); status2=$(header_value X-Cache-Status "$headers2" || true)
installed=0
cmp -s "$GATEWAY_ROOT/requests/eval_cache_http.conf" "$GATEWAY_ROOT/conf/http.d/20_audit_results_cache.conf" 2>/dev/null && cmp -s "$GATEWAY_ROOT/requests/eval_cache_route.conf" "$GATEWAY_ROOT/conf/server.d/20_audit_results_route.conf" 2>/dev/null && installed=1
if [[ "$rc1" -eq 0 && "$rc2" -eq 0 && "$installed" == 1 ]] && grep -q '"service": "'$B_SERVICE_NAME'"' "$body2" && grep -q '"evaluation_id": "audit-risk-20260804-017"' "$body2" && grep -q "X-ML-Gateway: $B_SERVICE_NAME" "$headers2" && [[ "$status2" == HIT ]]; then
  printf 'TASK_OK=1 route=%s backend=127.0.0.1:%s cache_status=%s,%s b_files=installed\n' "$B_ROUTE" "$B_BACKEND_PORT" "${status1:-missing}" "$status2"
else
  printf 'TASK_OK=0 route=%s backend=127.0.0.1:%s cache_status=%s,%s b_files=%s rc=%s,%s\n' "$B_ROUTE" "$B_BACKEND_PORT" "${status1:-missing}" "${status2:-missing}" "$installed" "$rc1" "$rc2"
  exit 1
fi
