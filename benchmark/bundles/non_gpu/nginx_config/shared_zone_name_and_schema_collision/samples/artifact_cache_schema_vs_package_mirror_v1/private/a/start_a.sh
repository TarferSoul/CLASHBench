#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$CASE_ROOT/lib/common.sh"
load_fixture
ensure_agent_user

write_workspace_base "$GATEWAY_ROOT"
write_nginx_conf "$GATEWAY_ROOT"
write_model_backend "$GATEWAY_ROOT"
write_eval_backend "$GATEWAY_ROOT"
write_a_includes "$GATEWAY_ROOT"

chown -R agentb:agentb "$GATEWAY_ROOT"
find "$GATEWAY_ROOT" -type d -exec chmod 755 {} +
find "$GATEWAY_ROOT" -type f -exec chmod 644 {} +
chmod 755 "$GATEWAY_ROOT/apps/package_index_service.py" \
  "$GATEWAY_ROOT/apps/eval_artifact_service.py" \
  "$GATEWAY_ROOT/scripts/reload_gateway.sh" \
  "$GATEWAY_ROOT/scripts/start_eval_backend.sh" \
  "$GATEWAY_ROOT/scripts/check_eval_cache.sh"

launch_agent_python_service \
  "$GATEWAY_ROOT/apps/package_index_service.py" \
  "$GATEWAY_ROOT/run/package_index.pid" \
  "$GATEWAY_ROOT/logs/package_index.log" \
  GATEWAY_ROOT="$GATEWAY_ROOT" A_BACKEND_PORT="$A_BACKEND_PORT" \
  A_SERVICE_NAME="$A_SERVICE_NAME" A_ROUTE="$A_ROUTE"
wait_port "$A_BACKEND_PORT" 120 0.1
nginx_test "$GATEWAY_ROOT" >/dev/null
start_nginx "$GATEWAY_ROOT"
wait_port "$GATEWAY_PORT" 120 0.1

mkdir -p "$RESULT_ROOT/evidence"
chmod 700 "$RESULT_ROOT" "$RESULT_ROOT/evidence"
if ! cache_pair_probe "$A_ROUTE" "start_$$" "$A_SERVICE_NAME" "$A_SERVICE_NAME" "$RESULT_ROOT/evidence" "a_start_cache" >/dev/null; then
  echo "A_START_FAIL=cache_route_unavailable" >&2
  exit 3
fi

printf 'A_STARTED nginx_pid=%s backend_pid=%s zone=%s size=%s route=%s\n' \
  "$(cat "$GATEWAY_ROOT/run/nginx.pid" 2>/dev/null || printf missing)" \
  "$(cat "$GATEWAY_ROOT/run/package_index.pid" 2>/dev/null || printf missing)" \
  "$CACHE_ZONE_NAME" "$A_CACHE_SIZE" "$A_ROUTE"

