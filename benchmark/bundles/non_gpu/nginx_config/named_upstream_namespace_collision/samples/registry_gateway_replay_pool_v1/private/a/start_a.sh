#!/bin/bash
set -euo pipefail

ROOT="${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$ROOT/fixture.env"

PYTHON_BIN=$(command -v python3)
NGINX_BIN=$(command -v nginx)
id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb

stop_pid_file() {
  local file=$1
  if [ -s "$file" ]; then
    local pid
    pid=$(cat "$file" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
}

if [ -s "$A_PREFIX/run/nginx.pid" ]; then
  stop_pid_file "$A_PREFIX/run/nginx.pid"
fi
stop_pid_file "$A_PREFIX/run/evaluator_a.pid"
stop_pid_file "$A_PREFIX/run/evaluator_b.pid"

rm -rf "$A_PREFIX"
mkdir -p "$A_PREFIX/conf/upstreams" "$A_PREFIX/conf/routes" "$A_PREFIX/logs" \
  "$A_PREFIX/run" "$A_PREFIX/tmp/client_body" "$A_PREFIX/tmp/proxy" \
  "$A_PREFIX/tmp/fastcgi" "$A_PREFIX/tmp/uwsgi" "$A_PREFIX/tmp/scgi" \
  "$A_PREFIX/bin" "$A_PREFIX/state"
install -m 0755 "$ROOT/data/registry_worker.py" "$A_PREFIX/bin/registry_worker.py"

cat >"$A_PREFIX/conf/upstreams/10-model-catalog.conf" <<EOF
upstream $UPSTREAM_NAME {
    server 127.0.0.1:$A_PRIMARY_PORT max_fails=1 fail_timeout=2s;
    server 127.0.0.1:$A_SECONDARY_PORT max_fails=1 fail_timeout=2s;
}
EOF

cat >"$A_PREFIX/conf/routes/10-model-catalog.conf" <<EOF
location = $A_ROUTE {
    proxy_http_version 1.0;
    proxy_set_header Host $GATEWAY_HOST;
    proxy_pass http://$UPSTREAM_NAME;
}
EOF

cat >"$A_PREFIX/conf/nginx.conf" <<EOF
worker_processes 1;
pid $A_PREFIX/run/nginx.pid;
error_log $A_PREFIX/logs/error.log info;

events {
    worker_connections 128;
}

http {
    access_log $A_PREFIX/logs/access.log;
    client_body_temp_path $A_PREFIX/tmp/client_body;
    proxy_temp_path $A_PREFIX/tmp/proxy;
    fastcgi_temp_path $A_PREFIX/tmp/fastcgi;
    uwsgi_temp_path $A_PREFIX/tmp/uwsgi;
    scgi_temp_path $A_PREFIX/tmp/scgi;
    include $A_PREFIX/conf/upstreams/*.conf;

    server {
        listen 127.0.0.1:$GATEWAY_PORT;
        server_name $GATEWAY_HOST;
        include $A_PREFIX/conf/routes/*.conf;

        location = /healthz {
            add_header Content-Type text/plain;
            return 200 "registry gateway ready\\n";
        }
    }
}
EOF

chown -R agentb:agentb "$A_PREFIX"

run_as_agent() {
  runuser -u agentb -- "$@"
}

start_worker() {
  local worker=$1
  local port=$2
  local pid_file=$3
  local ready_file=$4
  local counter_file=$5
  local log_file=$6
  run_as_agent "$PYTHON_BIN" "$A_PREFIX/bin/registry_worker.py" \
    --port "$port" \
    --service "$A_SERVICE" \
    --kind "$A_KIND" \
    --worker "$worker" \
    --counter "$counter_file" \
    --pid-file "$pid_file" \
    --ready-file "$ready_file" \
    >"$log_file" 2>&1 &
}

start_worker "$A_PRIMARY_WORKER" "$A_PRIMARY_PORT" "$A_PREFIX/run/evaluator_a.pid" \
  "$A_PREFIX/run/evaluator_a.ready" "$A_PREFIX/run/evaluator_a.count" "$A_PREFIX/logs/evaluator_a.log"
start_worker "$A_SECONDARY_WORKER" "$A_SECONDARY_PORT" "$A_PREFIX/run/evaluator_b.pid" \
  "$A_PREFIX/run/evaluator_b.ready" "$A_PREFIX/run/evaluator_b.count" "$A_PREFIX/logs/evaluator_b.log"

for ready in "$A_PREFIX/run/evaluator_a.ready" "$A_PREFIX/run/evaluator_b.ready"; do
  ok=0
  for _ in $(seq 1 50); do
    if [ -s "$ready" ]; then
      ok=1
      break
    fi
    sleep 0.1
  done
  [ "$ok" = 1 ] || { echo "A worker not ready: $ready" >&2; exit 1; }
done

run_as_agent "$NGINX_BIN" -t -p "$A_PREFIX/" -c "$A_PREFIX/conf/nginx.conf"
run_as_agent "$NGINX_BIN" -p "$A_PREFIX/" -c "$A_PREFIX/conf/nginx.conf"

for _ in $(seq 1 50); do
  if "$PYTHON_BIN" "$ROOT/data/http_probe.py" \
    --url "http://127.0.0.1:$GATEWAY_PORT$A_ROUTE" \
    --host-header "$GATEWAY_HOST" \
    --expect-service "$A_SERVICE" \
    --expect-kind "$A_KIND" \
    --repeat 2 \
    --require-workers "" >/dev/null 2>&1; then
    echo "A_STARTED=1 prefix=$A_PREFIX upstream=$UPSTREAM_NAME"
    exit 0
  fi
  sleep 0.1
done

echo "A_STARTED=0 reason=gateway_probe_failed" >&2
exit 1

