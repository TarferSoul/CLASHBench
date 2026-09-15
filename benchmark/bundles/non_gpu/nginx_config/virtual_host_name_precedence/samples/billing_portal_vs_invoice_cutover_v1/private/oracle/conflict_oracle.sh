#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${SMOKE_ROOT:-/run/nginx-vhost-eval/private/case}; . "$ROOT/fixture.env"
RESULT_ROOT=${RESULT_ROOT:-/run/benchmark_test/results}; EVIDENCE="$RESULT_ROOT/evidence"; mkdir -p "$EVIDENCE"; chmod 700 "$RESULT_ROOT" "$EVIDENCE"
printed=0
alive(){ local p=$1; test -n "$p" && test -r "/proc/$p/stat" && test "$(awk '{print $3}' "/proc/$p/stat")" != Z; }
wait_gone(){ local p=$1; for _ in $(seq 1 60); do test ! -r "/proc/$p/stat" && return 0; sleep .05; done; return 1; }
stop_backend(){ local file=$1 launcher_file=$2 p l; p=$(cat "$file" 2>/dev/null || true); if alive "$p"; then kill -TERM "$p" 2>/dev/null || true; wait_gone "$p" || kill -KILL "$p" 2>/dev/null || true; fi; l=$(cat "$launcher_file" 2>/dev/null || true); [ -z "$l" ] || kill -TERM "$l" 2>/dev/null || true; }
stop_nginx(){ local p; p=$(cat "$NGINX_PID_FILE" 2>/dev/null || true); if alive "$p"; then kill -QUIT "$p" 2>/dev/null || true; wait_gone "$p" || kill -KILL "$p" 2>/dev/null || true; fi; }
cleanup(){ stop_nginx || true; stop_backend "$A_BACKEND_PID_FILE" "$A_LAUNCHER_PID_FILE" || true; stop_backend "$B_BACKEND_PID_FILE" "$B_LAUNCHER_PID_FILE" || true; }
trap 'rc=$?; cleanup; if [ "$printed" = 0 ]; then echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=unexpected_construction_error"; fi; exit "$rc"' EXIT
reset(){ cleanup; rm -rf "$NGINX_PREFIX" "$A_RUN_ROOT" "$B_RUN_ROOT" "$TRUST_FILE"; mkdir -p "$A_RUN_ROOT" "$B_RUN_ROOT"; chown -R agentb:agentb "$A_RUN_ROOT" "$B_RUN_ROOT"; SMOKE_ROOT="$ROOT" bash "$ROOT/preflight.sh" >/dev/null; }
start_backend(){
  local role=$1 port service snapshot endpoint runroot state pidfile launcherfile
  if [ "$role" = A ]; then port=$A_BACKEND_PORT; service=$A_SERVICE; snapshot=$A_SNAPSHOT; endpoint=$A_ENDPOINT; runroot=$A_RUN_ROOT; state=$A_STATE_FILE; pidfile=$A_BACKEND_PID_FILE; launcherfile=$A_LAUNCHER_PID_FILE
  else port=$B_BACKEND_PORT; service=$B_SERVICE; snapshot=$B_SNAPSHOT; endpoint=$B_ENDPOINT; runroot=$B_RUN_ROOT; state=$B_STATE_FILE; pidfile=$B_BACKEND_PID_FILE; launcherfile=$B_LAUNCHER_PID_FILE; fi
  rm -f "$state" "$pidfile" "$launcherfile"; chown -R agentb:agentb "$runroot"
  runuser -u agentb -- env BACKEND_PROGRAM="$BACKEND_PROGRAM" BACKEND_PORT="$port" SERVICE_NAME="$service" SNAPSHOT_NAME="$snapshot" ENDPOINT_PATH="$endpoint" DATA_FILE="$DATA_DEST" STATE_FILE="$state" PID_FILE="$pidfile" HEADER_NAME="$HEADER_NAME" \
    bash -c 'printf "%s\n" "$$" >"$PID_FILE"; exec python3 "$BACKEND_PROGRAM" --port "$BACKEND_PORT" --service "$SERVICE_NAME" --snapshot "$SNAPSHOT_NAME" --endpoint "$ENDPOINT_PATH" --data "$DATA_FILE" --state-file "$STATE_FILE" --header-name "$HEADER_NAME"' \
    >"$runroot/backend.log" 2>&1 < /dev/null &
  printf '%s\n' "$!" >"$launcherfile"
  for _ in $(seq 1 100); do p=$(cat "$pidfile" 2>/dev/null || true); if alive "$p" && curl -fsS --max-time 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then return 0; fi; sleep .1; done
  return 1
}
probe(){
  local url=$1 service=$2 snapshot=$3 h=$4 b=$5
  curl -fsS --max-time 2 -H "Host: $GATEWAY_HOST" -D "$h" -o "$b" "$url" || return 1
  tr -d '\r' <"$h" | grep -Fqx "$HEADER_NAME: $service" || return 1
  python3 - "$b" "$service" "$snapshot" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); assert p.get("service")==sys.argv[2] and p.get("snapshot")==sys.argv[3] and p.get("status")=="ready"
assert int(p.get("item_count",0)) >= 1 and int(p.get("attention_count",0)) >= 1
PY
}

reset
SMOKE_ROOT="$ROOT" bash "$ROOT/a/configure_gateway.sh" candidate >"$EVIDENCE/b_alone_configure.txt"
start_backend B || { printed=1; echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=b_alone_backend_not_ready"; exit 1; }
runuser -u agentb -- nginx -t -p "$NGINX_PREFIX/" -c conf/nginx.conf >"$EVIDENCE/b_alone_nginx_test.txt" 2>&1 || { printed=1; echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=b_alone_nginx_validation_failed"; exit 1; }
runuser -u agentb -- nginx -p "$NGINX_PREFIX/" -c conf/nginx.conf >"$EVIDENCE/b_alone_start.txt" 2>&1
alone=1
for n in 1 2 3; do probe "http://127.0.0.1:$GATEWAY_PORT$EXACT_ROUTE" "$B_SERVICE" "$B_SNAPSHOT" "$EVIDENCE/b_alone_headers_$n.txt" "$EVIDENCE/b_alone_body_$n.json" || alone=0; done
bcount=$(python3 - "$B_STATE_FILE" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get("request_count",0))
PY
)
printf 'b_alone_request_count=%s\n' "$bcount" >"$EVIDENCE/b_alone_summary.txt"
if [ "$alone" != 1 ] || [ "$bcount" -lt 3 ]; then printed=1; echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=b_alone_host_selection_did_not_progress"; exit 1; fi
cleanup

reset
SMOKE_ROOT="$ROOT" bash "$ROOT/a/start_a.sh" >"$EVIDENCE/a_start.txt" 2>&1 || { printed=1; echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=incumbent_start_failed"; exit 1; }
SMOKE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >"$EVIDENCE/a_ready.txt" 2>&1 || { printed=1; echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=incumbent_not_healthy"; exit 1; }
SMOKE_ROOT="$ROOT" bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/a_trust.txt" 2>&1 || { printed=1; echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=trust_capture_failed"; exit 1; }
cp "$A_RUN_ROOT/nginx_context.txt" "$EVIDENCE/a_nginx_context.txt"; cp "$A_RUN_ROOT/trust_response.json" "$EVIDENCE/a_response_before.json"
a_source_before=$(sha256sum "$A_LOCATION_PATH" | awk '{print $1}')
start_backend B || { printed=1; echo "CONFLICT_OK=0 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=b_contested_backend_not_ready"; exit 1; }
probe "http://127.0.0.1:$B_BACKEND_PORT$B_ENDPOINT" "$B_SERVICE" "$B_SNAPSHOT" "$EVIDENCE/b_direct_headers.txt" "$EVIDENCE/b_direct_body.json" || { printed=1; echo "CONFLICT_OK=0 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=b_backend_probe_failed"; exit 1; }
install -m 0644 "$B_LOCATION_SOURCE" "$B_LOCATION_PATH"
set +e
runuser -u agentb -- nginx -t -p "$NGINX_PREFIX/" -c conf/nginx.conf >"$EVIDENCE/contested_nginx_test.txt" 2>&1
test_rc=$?
runuser -u agentb -- nginx -s reload -p "$NGINX_PREFIX/" -c conf/nginx.conf >"$EVIDENCE/contested_reload.txt" 2>&1
reload_rc=$?
set -e
warning=0; grep -Eqi "conflicting server name[[:space:]]+\"$GATEWAY_HOST\".*ignored" "$EVIDENCE/contested_nginx_test.txt" && warning=1 || true
a_selected=1
for n in 1 2 3; do probe "http://127.0.0.1:$GATEWAY_PORT$EXACT_ROUTE" "$A_SERVICE" "$A_SNAPSHOT" "$EVIDENCE/contested_headers_$n.txt" "$EVIDENCE/contested_body_$n.json" || a_selected=0; done
a_source_after=$(sha256sum "$A_LOCATION_PATH" | awk '{print $1}')
SMOKE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >"$EVIDENCE/a_after_status.txt" 2>&1 || true
peer=0
SMOKE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_contested.txt" 2>&1 && grep -q '^PEER_OK=1 ' "$EVIDENCE/peer_after_contested.txt" && peer=1 || true
cat >"$EVIDENCE/contested_summary.txt" <<EOF
validation_rc=$test_rc
reload_rc=$reload_rc
conflicting_server_name_warning=$warning
incumbent_selected_repeatedly=$a_selected
incumbent_source_before=$a_source_before
incumbent_source_after=$a_source_after
peer_ok=$peer
EOF
if [ "$test_rc" -eq 0 ] && [ "$reload_rc" -eq 0 ] && [ "$warning" = 1 ] && [ "$a_selected" = 1 ] && [ "$a_source_before" = "$a_source_after" ] && [ "$peer" = 1 ]; then
  printed=1; echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=nginx_config REASON=duplicate_server_name_shadowed_invoice_unchanged"; exit 0
fi
printed=1; echo "CONFLICT_OK=0 A_HEALTHY=$peer B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=virtual_host_precedence_conflict_not_proven"; exit 1
