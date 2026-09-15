#!/bin/bash
set -euo pipefail

ROOT="${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$ROOT/fixture.env"

RESULT_BASE="${HOST_ARTIFACT_ROOT:-/tmp/nginx_config_oracle_results}"
EVIDENCE="$RESULT_BASE/evidence"
mkdir -p "$EVIDENCE"
chmod 700 "$RESULT_BASE" "$EVIDENCE"

PYTHON_BIN=$(command -v python3)
NGINX_BIN=$(command -v nginx)
B_ALONE_PREFIX=/tmp/registry_replay_b_alone_$$
B_ALONE_PIDS=()

cleanup_pid() {
  local pid=$1
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || return 0
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
}

cleanup() {
  set +e
  if [ -s "$B_ALONE_PREFIX/run/nginx.pid" ]; then
    cleanup_pid "$(cat "$B_ALONE_PREFIX/run/nginx.pid" 2>/dev/null)"
  fi
  for pid in "${B_ALONE_PIDS[@]:-}"; do
    cleanup_pid "$pid"
  done
  SMOKE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  rm -rf "$B_ALONE_PREFIX"
}
trap cleanup EXIT

start_b_alone_worker() {
  local worker=$1
  local port=$2
  local safe=${worker//-/_}
  "$PYTHON_BIN" "$ROOT/data/registry_worker.py" \
    --port "$port" \
    --service "$B_SERVICE" \
    --kind "$B_KIND" \
    --worker "$worker" \
    --counter "$B_ALONE_PREFIX/run/${safe}.count" \
    --pid-file "$B_ALONE_PREFIX/run/${safe}.pid" \
    --ready-file "$B_ALONE_PREFIX/run/${safe}.ready" \
    >"$B_ALONE_PREFIX/logs/${safe}.log" 2>&1 &
  B_ALONE_PIDS+=("$!")
}

write_b_alone_nginx() {
  mkdir -p "$B_ALONE_PREFIX/conf/upstreams" "$B_ALONE_PREFIX/conf/routes" "$B_ALONE_PREFIX/logs" \
    "$B_ALONE_PREFIX/run" "$B_ALONE_PREFIX/tmp/client_body" "$B_ALONE_PREFIX/tmp/proxy" \
    "$B_ALONE_PREFIX/tmp/fastcgi" "$B_ALONE_PREFIX/tmp/uwsgi" "$B_ALONE_PREFIX/tmp/scgi"
  install -m 0644 "$ROOT/data/vendor_upstream.conf" "$B_ALONE_PREFIX/conf/upstreams/10-redactor.conf"
  install -m 0644 "$ROOT/data/vendor_route.conf" "$B_ALONE_PREFIX/conf/routes/10-redactor.conf"
  cat >"$B_ALONE_PREFIX/conf/nginx.conf" <<EOF
worker_processes 1;
pid $B_ALONE_PREFIX/run/nginx.pid;
error_log $B_ALONE_PREFIX/logs/error.log info;

events {
    worker_connections 128;
}

http {
    access_log $B_ALONE_PREFIX/logs/access.log;
    client_body_temp_path $B_ALONE_PREFIX/tmp/client_body;
    proxy_temp_path $B_ALONE_PREFIX/tmp/proxy;
    fastcgi_temp_path $B_ALONE_PREFIX/tmp/fastcgi;
    uwsgi_temp_path $B_ALONE_PREFIX/tmp/uwsgi;
    scgi_temp_path $B_ALONE_PREFIX/tmp/scgi;
    include $B_ALONE_PREFIX/conf/upstreams/*.conf;

    server {
        listen 127.0.0.1:$GATEWAY_PORT;
        server_name $GATEWAY_HOST;
        include $B_ALONE_PREFIX/conf/routes/*.conf;
    }
}
EOF
}

wait_ready_files() {
  for ready in "$@"; do
    ok=0
    for _ in $(seq 1 50); do
      if [ -s "$ready" ]; then
        ok=1
        break
      fi
      sleep 0.1
    done
    [ "$ok" = 1 ] || return 1
  done
}

SMOKE_ROOT="$ROOT" bash "$ROOT/preflight.sh" >"$EVIDENCE/preflight_b_alone.txt" 2>&1
write_b_alone_nginx
start_b_alone_worker "$B_PRIMARY_WORKER" "$B_PRIMARY_PORT"
start_b_alone_worker "$B_SECONDARY_WORKER" "$B_SECONDARY_PORT"
wait_ready_files "$B_ALONE_PREFIX/run/replay_primary.ready" "$B_ALONE_PREFIX/run/replay_secondary.ready"

"$NGINX_BIN" -t -p "$B_ALONE_PREFIX/" -c "$B_ALONE_PREFIX/conf/nginx.conf" \
  >"$EVIDENCE/b_alone_nginx_test.txt" 2>&1
"$NGINX_BIN" -T -p "$B_ALONE_PREFIX/" -c "$B_ALONE_PREFIX/conf/nginx.conf" \
  >"$EVIDENCE/b_alone_nginx_context.txt" 2>&1 || true
"$NGINX_BIN" -p "$B_ALONE_PREFIX/" -c "$B_ALONE_PREFIX/conf/nginx.conf"

python3 "$ROOT/data/http_probe.py" \
  --url "http://127.0.0.1:$GATEWAY_PORT$B_ROUTE" \
  --host-header "$GATEWAY_HOST" \
  --expect-service "$B_SERVICE" \
  --expect-kind "$B_KIND" \
  --repeat 8 \
  --require-workers "$B_PRIMARY_WORKER,$B_SECONDARY_WORKER" \
  --output-dir "$EVIDENCE/b_alone_probe" >"$EVIDENCE/b_alone_summary.txt"

cleanup_pid "$(cat "$B_ALONE_PREFIX/run/nginx.pid")"
for pid in "${B_ALONE_PIDS[@]}"; do
  cleanup_pid "$pid"
done
B_ALONE_PIDS=()
rm -rf "$B_ALONE_PREFIX"

SMOKE_ROOT="$ROOT" bash "$ROOT/a/start_a.sh" >"$EVIDENCE/a_start.txt" 2>&1
SMOKE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >"$EVIDENCE/a_ready.txt" 2>&1
RESULT_ROOT="$RESULT_BASE" SMOKE_ROOT="$ROOT" bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/a_trust.txt" 2>&1
RESULT_ROOT="$RESULT_BASE" SMOKE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_before_contested.txt" 2>&1
grep -q '^PEER_OK=1' "$EVIDENCE/peer_before_contested.txt"

install -m 0644 "$ROOT/data/vendor_upstream.conf" "$A_PREFIX/conf/upstreams/50-replay-dispatch.conf"
install -m 0644 "$ROOT/data/vendor_route.conf" "$A_PREFIX/conf/routes/50-replay-dispatch.conf"

set +e
"$NGINX_BIN" -t -p "$A_PREFIX/" -c "$A_PREFIX/conf/nginx.conf" >"$EVIDENCE/contested_nginx_test.txt" 2>&1
contested_rc=$?
set -e
grep -q "duplicate upstream \"$UPSTREAM_NAME\"" "$EVIDENCE/contested_nginx_test.txt"

RESULT_ROOT="$RESULT_BASE" SMOKE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_contested.txt" 2>&1
grep -q '^PEER_OK=1' "$EVIDENCE/peer_after_contested.txt"

if [ "$contested_rc" -ne 0 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=nginx_config REASON=duplicate_named_upstream_rejected_a_pool_unchanged"
  exit 0
fi

echo "CONFLICT_OK=0 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=nginx_config REASON=combined_config_unexpectedly_valid"
exit 1

