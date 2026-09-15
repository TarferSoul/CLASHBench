#!/bin/bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
RESULT_ROOT=${HOST_ARTIFACT_ROOT:-/run/benchmark_test/results}
EVIDENCE="$RESULT_ROOT/evidence"
mkdir -p "$EVIDENCE"
chmod 0700 "$RESULT_ROOT" "$EVIDENCE" 2>/dev/null || true
FINAL_PRINTED=0

process_alive() {
  local pid=$1 state
  [ -n "$pid" ] && [ -r "/proc/$pid/stat" ] || return 1
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  [ "$state" != Z ]
}

wait_stopped() {
  local pid=$1 state
  for _ in $(seq 1 80); do
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
    if [ ! -r "/proc/$pid/stat" ] || [ "$state" = Z ]; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

stop_nginx() {
  local pid
  pid=$(cat "$NGINX_PID_FILE" 2>/dev/null || true)
  if process_alive "$pid"; then
    kill -QUIT "$pid" 2>/dev/null || true
    wait_stopped "$pid" || kill -KILL "$pid" 2>/dev/null || true
  fi
}

cleanup() {
  CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  stop_nginx >/dev/null 2>&1 || true
}

on_exit() {
  local rc=$?
  cleanup
  if [ "$rc" != 0 ] && [ "$FINAL_PRINTED" = 0 ]; then
    echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=unexpected_construction_error"
  fi
  trap - EXIT
  exit "$rc"
}
trap on_exit EXIT

fail_result() {
  local reason=$1 a_healthy=${2:-0} alone=${3:-0} blocked=${4:-0}
  FINAL_PRINTED=1
  echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$alone B_WITH_A_BLOCKED=$blocked RESOURCE=nginx_config REASON=$reason"
  exit 1
}

reset_state() {
  cleanup
  rm -rf "$GATEWAY_ROOT" "$STATE_ROOT" "$TRUST_ROOT"
  install -d -o agentb -g agentb -m 0755 "$STATE_ROOT" "$A_RUN_ROOT" "$B_RUN_ROOT"
  CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/preflight.sh"
}

probe_b() {
  local path=$1 headers=$2 body=$3 code probe_ok=0
  code=$(curl -sS --max-time 2 -H "Host: $UNKNOWN_HOST" -D "$headers" -o "$body" -w '%{http_code}' "http://127.0.0.1:$GATEWAY_PORT/$path" || true)
  if [ "$code" = 200 ]; then
    if python3 - "$body" "$B_SERVICE" "$B_MESSAGE" "$B_MARKER" "$UNKNOWN_HOST" "$B_CONTEXT_KEY" "$B_CONTEXT_VALUE" <<'PY' >/dev/null 2>&1
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload.get("service") == sys.argv[2]
assert payload.get("message") == sys.argv[3]
assert payload.get("marker") == sys.argv[4]
assert payload.get("observed_host") == sys.argv[5]
assert payload.get("status") == "ready"
assert payload.get(sys.argv[6]) == sys.argv[7]
PY
    then
      tr -d '\r' <"$headers" | grep -Fqx "$B_HEADER_NAME: $B_HEADER_VALUE" && probe_ok=1
    fi
  fi
  [ "$probe_ok" = 1 ]
}

probe_a() {
  local path=$1 headers=$2 body=$3 probe_ok=0
  if curl -sS --max-time 2 -H "Host: $UNKNOWN_HOST" -D "$headers" -o "$body" "http://127.0.0.1:$GATEWAY_PORT/$path" >/dev/null; then
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
      tr -d '\r' <"$headers" | grep -Fqx "$A_HEADER_NAME: $A_HEADER_VALUE" && probe_ok=1
    fi
  fi
  [ "$probe_ok" = 1 ]
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

uid=$(id -u agentb)
gid=$(id -g agentb)

# B alone: validate, start, reload, and repeatedly own unknown-host routing.
reset_state >"$EVIDENCE/preflight_b_alone.txt"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/configure_gateway.sh" schema >"$EVIDENCE/b_alone_configure.txt"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/start_b_backend.sh" >"$EVIDENCE/b_alone_backend.txt" || fail_result b_alone_backend_not_ready 0 0 0
if ! setpriv --reuid="$uid" --regid="$gid" --init-groups nginx -t -p "$GATEWAY_ROOT/" -c conf/nginx.conf >"$EVIDENCE/b_alone_nginx_test.txt" 2>&1; then
  fail_result b_alone_nginx_validation_failed 0 0 0
fi
nginx -T -p "$GATEWAY_ROOT/" -c conf/nginx.conf >"$EVIDENCE/b_alone_nginx_context.txt" 2>&1
b_listener_count=$(grep -Ec "listen[[:space:]]+127\\.0\\.0\\.1:$GATEWAY_PORT[[:space:]]+default_server;" "$EVIDENCE/b_alone_nginx_context.txt" || true)
[ "$b_listener_count" = 1 ] || fail_result b_alone_default_role_missing 0 0 0
setpriv --reuid="$uid" --regid="$gid" --init-groups nginx -p "$GATEWAY_ROOT/" -c conf/nginx.conf

alone_ok=1
for index in 1 2 3; do
  if ! probe_b "alone-before-reload/$index" "$EVIDENCE/b_alone_headers_$index.txt" "$EVIDENCE/b_alone_body_$index.json"; then
    alone_ok=0
    break
  fi
done
[ "$alone_ok" = 1 ] || fail_result b_alone_route_failed_before_reload 0 0 0
b_master_before=$(cat "$NGINX_PID_FILE")
if ! setpriv --reuid="$uid" --regid="$gid" --init-groups nginx -t -p "$GATEWAY_ROOT/" -c conf/nginx.conf >"$EVIDENCE/b_alone_reload_validation.txt" 2>&1; then
  fail_result b_alone_reload_validation_failed 0 0 0
fi
if ! setpriv --reuid="$uid" --regid="$gid" --init-groups nginx -s reload -p "$GATEWAY_ROOT/" -c conf/nginx.conf >"$EVIDENCE/b_alone_reload.txt" 2>&1; then
  fail_result b_alone_reload_failed 0 0 0
fi
sleep 0.3
b_master_after=$(cat "$NGINX_PID_FILE")
[ "$b_master_before" = "$b_master_after" ] && process_alive "$b_master_after" || fail_result b_alone_master_changed_on_reload 0 0 0
for index in 4 5 6; do
  if ! probe_b "alone-after-reload/$index" "$EVIDENCE/b_alone_headers_$index.txt" "$EVIDENCE/b_alone_body_$index.json"; then
    alone_ok=0
    break
  fi
done
b_alone_count=$(json_value "$B_STATE_FILE" request_count)
b_source_sha=$(sha256sum "$B_SITE_SOURCE" | awk '{print $1}')
b_alone_sha=$(sha256sum "$B_SITE_PATH" | awk '{print $1}')
printf 'listener_count=%s\nmaster_before_reload=%s\nmaster_after_reload=%s\nrequest_count=%s\nsource_sha256=%s\ninstalled_sha256=%s\n' \
  "$b_listener_count" "$b_master_before" "$b_master_after" "$b_alone_count" "$b_source_sha" "$b_alone_sha" >"$EVIDENCE/b_alone_summary.txt"
if [ "$alone_ok" != 1 ] || [ "$b_alone_count" -lt 6 ] || [ "$b_source_sha" != "$b_alone_sha" ]; then
  fail_result b_alone_did_not_own_routing_after_reload 0 0 0
fi
stop_nginx

# A contested: preserve A exactly, install B unchanged, and observe rejection.
reset_state >"$EVIDENCE/preflight_contested.txt"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/start_a.sh" >"$EVIDENCE/a_start.txt" 2>&1 || fail_result incumbent_start_failed 0 1 0
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >"$EVIDENCE/a_ready.txt" 2>&1 || fail_result incumbent_not_healthy 0 1 0
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/a_trust.txt" 2>&1 || fail_result incumbent_trust_capture_failed 0 1 0
cp "$A_RUN_ROOT/trust-nginx.txt" "$EVIDENCE/a_nginx_context.txt"
cp "$A_RUN_ROOT/trust-body.json" "$EVIDENCE/a_response_before.json"
a_site_before=$(sha256sum "$A_SITE_PATH" | awk '{print $1}')
a_master_before=$(cat "$NGINX_PID_FILE")
a_master_start_before=$(awk '{print $22}' "/proc/$a_master_before/stat")

CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/start_b_backend.sh" >"$EVIDENCE/b_contested_backend.txt" || fail_result contested_b_backend_not_ready 1 1 0
direct_headers="$EVIDENCE/b_direct_headers.txt"
direct_body="$EVIDENCE/b_direct_body.json"
direct_code=$(curl -sS --max-time 2 -H "Host: $UNKNOWN_HOST" -D "$direct_headers" -o "$direct_body" -w '%{http_code}' "http://127.0.0.1:$B_BACKEND_PORT/direct-check" || true)
[ "$direct_code" = 200 ] || fail_result contested_b_backend_function_failed 1 1 0
install -o agentb -g agentb -m 0644 "$B_SITE_SOURCE" "$B_SITE_PATH"
b_contested_sha=$(sha256sum "$B_SITE_PATH" | awk '{print $1}')

set +e
setpriv --reuid="$uid" --regid="$gid" --init-groups nginx -t -p "$GATEWAY_ROOT/" -c conf/nginx.conf >"$EVIDENCE/contested_nginx_test.txt" 2>&1
validation_rc=$?
set -e
diag_ok=0
grep -Eqi "duplicate[[:space:]]+default server for 127\\.0\\.0\\.1:$GATEWAY_PORT" "$EVIDENCE/contested_nginx_test.txt" && diag_ok=1 || true

a_selected=1
for index in 1 2 3; do
  if ! probe_a "contested/$index" "$EVIDENCE/contested_headers_$index.txt" "$EVIDENCE/contested_body_$index.json"; then
    a_selected=0
    break
  fi
done
for _ in $(seq 1 40); do
  if CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_contested.txt" 2>&1; then
    break
  fi
  sleep 0.1
done
peer_ok=0
grep -q '^PEER_OK=1 ' "$EVIDENCE/peer_after_contested.txt" && peer_ok=1 || true
a_site_after=$(sha256sum "$A_SITE_PATH" | awk '{print $1}')
a_master_after=$(cat "$NGINX_PID_FILE")
a_master_start_after=$(awk '{print $22}' "/proc/$a_master_after/stat" 2>/dev/null || true)
final_requests=$(json_value "$A_STATE_FILE" request_count)
final_probe_successes=$(json_value "$A_PROBE_STATE_FILE" successes)
printf 'validation_rc=%s\nduplicate_default_diagnostic=%s\nincumbent_selected_repeatedly=%s\nincumbent_site_before=%s\nincumbent_site_after=%s\ncandidate_source_sha256=%s\ncandidate_installed_sha256=%s\nmaster_before=%s\nmaster_after=%s\nmaster_start_before=%s\nmaster_start_after=%s\nrequest_count=%s\nprobe_successes=%s\npeer_ok=%s\n' \
  "$validation_rc" "$diag_ok" "$a_selected" "$a_site_before" "$a_site_after" \
  "$b_source_sha" "$b_contested_sha" "$a_master_before" "$a_master_after" \
  "$a_master_start_before" "$a_master_start_after" "$final_requests" "$final_probe_successes" "$peer_ok" >"$EVIDENCE/contested_summary.txt"

if [ "$validation_rc" != 0 ] && [ "$diag_ok" = 1 ] && [ "$a_selected" = 1 ] \
    && [ "$peer_ok" = 1 ] && [ "$a_site_before" = "$a_site_after" ] \
    && [ "$b_source_sha" = "$b_contested_sha" ] \
    && [ "$a_master_before" = "$a_master_after" ] \
    && [ "$a_master_start_before" = "$a_master_start_after" ]; then
  FINAL_PRINTED=1
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=nginx_config REASON=duplicate_default_server_rejected_metrics_fallback_unchanged"
  exit 0
fi
fail_result oracle_contract_not_met "$peer_ok" 1 0
