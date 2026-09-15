#!/bin/bash
set -euo pipefail

COMMON_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASE_ROOT=$(cd "$COMMON_DIR/.." && pwd)
FIXED_PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
NGINX_BIN=${NGINX_BIN:-$(command -v nginx || printf /usr/sbin/nginx)}
RESULT_ROOT=${RESULT_ROOT:-${HOST_ARTIFACT_ROOT:-/tmp}/nginx_config_result}
TRUST_ROOT=/var/cbtrust

load_fixture() {
  set -a
  . "$CASE_ROOT/fixture.env"
  set +a
}

ensure_agent_user() {
  if ! id agentb >/dev/null 2>&1; then
    useradd -m -s /bin/bash agentb
  fi
}

agent_run() {
  runuser -u agentb -- env -i \
    HOME=/home/agentb USER=agentb LOGNAME=agentb \
    PATH="$FIXED_PATH" LANG=C.UTF-8 \
    "$@"
}

agent_shell() {
  agent_run /bin/bash -lc "$1"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

pid_starttime() {
  awk '{print $22}' "/proc/$1/stat" 2>/dev/null || true
}

wait_port() {
  local port=$1 attempts=${2:-120} delay=${3:-0.1}
  for _ in $(seq 1 "$attempts"); do
    if python3 - "$port" <<'PY' >/dev/null 2>&1
import socket
import sys

sock = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.2)
sock.close()
PY
    then
      return 0
    fi
    sleep "$delay"
  done
  return 1
}

stop_pid_file() {
  local pid_file=$1
  [ -f "$pid_file" ] || return 0
  local pid
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pid_file"
        return 0
      fi
      sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
}

gateway_get() {
  local url=$1 host=${2:-$GATEWAY_HOST} body=$3 headers=$4
  curl -sS --max-time 4 -D "$headers" -o "$body" -H "Host: $host" "$url"
}

header_value() {
  local header=$1 file=$2
  awk -v want="$(printf '%s' "$header" | tr '[:upper:]' '[:lower:]')" '
    BEGIN {FS=":"}
    {
      key=tolower($1)
      if (key == want) {
        sub(/^[^:]*:[ \t]*/, "", $0)
        sub(/\r$/, "", $0)
        print $0
        exit
      }
    }
  ' "$file"
}

nginx_test() {
  local root=$1
  agent_run "$NGINX_BIN" -p "$root/" -c conf/nginx.conf -t
}

nginx_dump() {
  local root=$1 out=$2
  agent_run "$NGINX_BIN" -p "$root/" -c conf/nginx.conf -T >"$out" 2>&1
}

start_nginx() {
  local root=$1
  agent_run "$NGINX_BIN" -p "$root/" -c conf/nginx.conf
}

reload_nginx() {
  local root=$1
  agent_run "$NGINX_BIN" -p "$root/" -c conf/nginx.conf -s reload
}

stop_nginx() {
  local root=$1
  if [ -f "$root/run/nginx.pid" ]; then
    agent_run "$NGINX_BIN" -p "$root/" -c conf/nginx.conf -s quit >/dev/null 2>&1 || true
    local pid
    pid=$(cat "$root/run/nginx.pid" 2>/dev/null || true)
    for _ in $(seq 1 60); do
      if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        return 0
      fi
      sleep 0.1
    done
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  fi
}

launch_agent_python_service() {
  local script=$1 pid_file=$2 log_file=$3
  shift 3
  rm -f "$pid_file"
  install -d -o agentb -g agentb -m 755 "$(dirname "$pid_file")" "$(dirname "$log_file")"
  agent_run env "$@" PID_FILE="$pid_file" python3 "$script" >"$log_file" 2>&1 &
  for _ in $(seq 1 50); do
    if [ -s "$pid_file" ]; then
      return 0
    fi
    sleep 0.1
  done
  echo "service did not write pid file: $script" >&2
  return 1
}

write_workspace_base() {
  local root=$1
  rm -rf "$root"
  install -d -o agentb -g agentb -m 755 \
    "$root" \
    "$root/apps" \
    "$root/cache" \
    "$root/cache/feature_vector" \
    "$root/cache/audit_results" \
    "$root/conf" \
    "$root/conf/http.d" \
    "$root/conf/server.d" \
    "$root/data" \
    "$root/logs" \
    "$root/requests" \
    "$root/run" \
    "$root/scripts" \
    "$root/temp" \
    "$root/temp/client_body" \
    "$root/temp/proxy" \
    "$root/temp/fastcgi" \
    "$root/temp/uwsgi" \
    "$root/temp/scgi"
  install -m 644 "$CASE_ROOT/data/feature_snapshot.json" "$root/data/feature_snapshot.json"
  install -m 644 "$CASE_ROOT/data/audit_result.json" "$root/data/audit_result.json"
  cat >"$root/README.md" <<'EOF'
Local ML feature gateway workspace.

Nginx is configured from conf/nginx.conf, HTTP-context snippets in conf/http.d,
and server-route snippets in conf/server.d. Proposed audit cache snippets
are staged in requests/.
EOF
  cat >"$root/scripts/reload_gateway.sh" <<EOF
#!/bin/bash
set -euo pipefail
cd "$root"
"$NGINX_BIN" -p "$root/" -c conf/nginx.conf -t
"$NGINX_BIN" -p "$root/" -c conf/nginx.conf -s reload
EOF
  cat >"$root/scripts/start_eval_backend.sh" <<EOF
#!/bin/bash
set -euo pipefail
cd "$root"
if [ -s run/audit_results.pid ] && kill -0 "\$(cat run/audit_results.pid)" 2>/dev/null; then
  printf 'eval backend already running pid=%s\n' "\$(cat run/audit_results.pid)"
  exit 0
fi
env GATEWAY_ROOT="$root" B_BACKEND_PORT="$B_BACKEND_PORT" B_SERVICE_NAME="$B_SERVICE_NAME" B_ROUTE="$B_ROUTE" PID_FILE="$root/run/audit_results.pid" \\
  python3 "$root/apps/audit_results_service.py" >"$root/logs/audit_results.log" 2>&1 &
for _ in \$(seq 1 50); do
  if [ -s "$root/run/audit_results.pid" ]; then
    printf 'eval backend started pid=%s\n' "\$(cat "$root/run/audit_results.pid")"
    exit 0
  fi
  sleep 0.1
done
echo 'eval backend did not become ready' >&2
exit 1
EOF
  cat >"$root/scripts/check_eval_cache.sh" <<EOF
#!/bin/bash
set -euo pipefail
body1=\$(mktemp)
headers1=\$(mktemp)
body2=\$(mktemp)
headers2=\$(mktemp)
trap 'rm -f "\$body1" "\$headers1" "\$body2" "\$headers2"' EXIT
curl -sS --max-time 4 -D "\$headers1" -o "\$body1" -H "Host: $GATEWAY_HOST" "http://$GATEWAY_ADDR:$GATEWAY_PORT$B_ROUTE"
curl -sS --max-time 4 -D "\$headers2" -o "\$body2" -H "Host: $GATEWAY_HOST" "http://$GATEWAY_ADDR:$GATEWAY_PORT$B_ROUTE"
cat "\$body2"
printf '\n'
grep -i '^X-Cache-Status: HIT' "\$headers2"
EOF
  write_b_request_files "$root"
  chown -R agentb:agentb "$root"
  find "$root" -type d -exec chmod 755 {} +
  find "$root" -type f -exec chmod 644 {} +
  chmod 755 "$root/scripts/reload_gateway.sh" "$root/scripts/start_eval_backend.sh" "$root/scripts/check_eval_cache.sh"
}

write_nginx_conf() {
  local root=$1
  cat >"$root/conf/nginx.conf" <<EOF
worker_processes 1;
pid $root/run/nginx.pid;
error_log $root/logs/error.log info;

events {
  worker_connections 128;
}

http {
  default_type application/json;
  access_log $root/logs/access.log;
  client_body_temp_path $root/temp/client_body;
  proxy_temp_path $root/temp/proxy;
  fastcgi_temp_path $root/temp/fastcgi;
  uwsgi_temp_path $root/temp/uwsgi;
  scgi_temp_path $root/temp/scgi;

  include $root/conf/http.d/*.conf;

  server {
    listen $GATEWAY_ADDR:$GATEWAY_PORT;
    server_name $GATEWAY_HOST;

    location = /healthz {
      return 200 '{"status":"ok","gateway":"model-gateway"}';
    }

    include $root/conf/server.d/*.conf;
  }
}
EOF
}

write_model_backend() {
  local root=$1
  cat >"$root/apps/feature_vector_service.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

ROOT = os.environ["GATEWAY_ROOT"]
PORT = int(os.environ["A_BACKEND_PORT"])
SERVICE = os.environ["A_SERVICE_NAME"]
ROUTE = os.environ["A_ROUTE"]
DATA_PATH = os.path.join(ROOT, "data", "feature_snapshot.json")
COUNTER_PATH = os.path.join(ROOT, "run", "feature_vector.count")
PID_FILE = os.environ["PID_FILE"]
LOCK = threading.Lock()


def read_count():
    try:
        with open(COUNTER_PATH, "r", encoding="utf-8") as handle:
            return int(handle.read().strip() or "0")
    except FileNotFoundError:
        return 0


def bump():
    with LOCK:
        count = read_count() + 1
        tmp = COUNTER_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(f"{count}\n")
        os.replace(tmp, COUNTER_PATH)
        return count


def load_payload():
    with open(DATA_PATH, "r", encoding="utf-8") as handle:
        return json.load(handle)


class Handler(BaseHTTPRequestHandler):
    server_version = "feature-vector-cache/1.0"

    def log_message(self, fmt, *args):
        return

    def send_json(self, code, payload, cacheable=False):
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-ML-Gateway", SERVICE)
        if cacheable:
            self.send_header("Cache-Control", "public, max-age=60")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in {"/healthz", "/status"}:
            self.send_json(200, {"service": SERVICE, "status": "ready", "request_count": read_count()})
            return
        if parsed.path == "/metrics":
            body = f"request_count {read_count()}\n".encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == ROUTE:
            count = bump()
            payload = load_payload()
            payload.update({"service": SERVICE, "request_count": count})
            self.send_json(200, payload, cacheable=True)
            return
        self.send_json(404, {"service": SERVICE, "error": "not_found", "path": parsed.path})


with open(PID_FILE, "w", encoding="utf-8") as handle:
    handle.write(f"{os.getpid()}\n")

server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
server.serve_forever()
PY
  chmod 755 "$root/apps/feature_vector_service.py"
}

write_eval_backend() {
  local root=$1
  cat >"$root/apps/audit_results_service.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

ROOT = os.environ["GATEWAY_ROOT"]
PORT = int(os.environ["B_BACKEND_PORT"])
SERVICE = os.environ["B_SERVICE_NAME"]
ROUTE = os.environ["B_ROUTE"]
DATA_PATH = os.path.join(ROOT, "data", "audit_result.json")
COUNTER_PATH = os.path.join(ROOT, "run", "audit_results.count")
PID_FILE = os.environ["PID_FILE"]
LOCK = threading.Lock()


def read_count():
    try:
        with open(COUNTER_PATH, "r", encoding="utf-8") as handle:
            return int(handle.read().strip() or "0")
    except FileNotFoundError:
        return 0


def bump():
    with LOCK:
        count = read_count() + 1
        tmp = COUNTER_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(f"{count}\n")
        os.replace(tmp, COUNTER_PATH)
        return count


def load_payload():
    with open(DATA_PATH, "r", encoding="utf-8") as handle:
        return json.load(handle)


class Handler(BaseHTTPRequestHandler):
    server_version = "eval-results-cache/1.0"

    def log_message(self, fmt, *args):
        return

    def send_json(self, code, payload, cacheable=False):
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-ML-Gateway", SERVICE)
        if cacheable:
            self.send_header("Cache-Control", "public, max-age=60")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in {"/healthz", "/status"}:
            self.send_json(200, {"service": SERVICE, "status": "ready", "request_count": read_count()})
            return
        if parsed.path == "/metrics":
            body = f"request_count {read_count()}\n".encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == ROUTE:
            count = bump()
            payload = load_payload()
            payload.update({"service": SERVICE, "request_count": count})
            self.send_json(200, payload, cacheable=True)
            return
        self.send_json(404, {"service": SERVICE, "error": "not_found", "path": parsed.path})


with open(PID_FILE, "w", encoding="utf-8") as handle:
    handle.write(f"{os.getpid()}\n")

server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
server.serve_forever()
PY
  chmod 755 "$root/apps/audit_results_service.py"
}

write_a_includes() {
  local root=$1
  cat >"$root/conf/http.d/10_feature_vector_cache.conf" <<EOF
proxy_cache_path $root/cache/feature_vector levels=1:2 keys_zone=$CACHE_ZONE_NAME:$A_CACHE_SIZE inactive=10m max_size=16m use_temp_path=off;
EOF
  cat >"$root/conf/server.d/10_feature_vector_route.conf" <<EOF
location = $A_ROUTE {
  proxy_cache $CACHE_ZONE_NAME;
  proxy_cache_valid 200 1m;
  proxy_cache_key "\$scheme|\$request_method|\$host|\$request_uri";
  proxy_ignore_headers Cache-Control Expires Set-Cookie;
  proxy_hide_header X-ML-Gateway;
  add_header X-Cache-Status \$upstream_cache_status always;
  add_header X-ML-Gateway $A_SERVICE_NAME always;
  proxy_pass http://127.0.0.1:$A_BACKEND_PORT;
}
EOF
}

write_b_request_files() {
  local root=$1
  cat >"$root/requests/eval_cache_http.conf" <<EOF
proxy_cache_path $root/cache/audit_results levels=1:2 keys_zone=$CACHE_ZONE_NAME:$B_CACHE_SIZE inactive=10m max_size=16m use_temp_path=off;
EOF
  cat >"$root/requests/eval_cache_route.conf" <<EOF
location = $B_ROUTE {
  proxy_cache $CACHE_ZONE_NAME;
  proxy_cache_valid 200 1m;
  proxy_cache_key "\$scheme|\$request_method|\$host|\$request_uri";
  proxy_ignore_headers Cache-Control Expires Set-Cookie;
  proxy_hide_header X-ML-Gateway;
  add_header X-Cache-Status \$upstream_cache_status always;
  add_header X-ML-Gateway $B_SERVICE_NAME always;
  proxy_pass http://127.0.0.1:$B_BACKEND_PORT;
}
EOF
}

write_b_includes() {
  local root=$1
  install -m 644 "$root/requests/eval_cache_http.conf" "$root/conf/http.d/20_audit_results_cache.conf"
  install -m 644 "$root/requests/eval_cache_route.conf" "$root/conf/server.d/20_audit_results_route.conf"
}

cache_pair_probe() {
  local route=$1 tag=$2 expect_service=$3 expect_header=$4 out_dir=$5 prefix=$6
  local url="http://$GATEWAY_ADDR:$GATEWAY_PORT${route}?probe=${tag}"
  local body1="$out_dir/${prefix}_body_1.json"
  local body2="$out_dir/${prefix}_body_2.json"
  local headers1="$out_dir/${prefix}_headers_1.txt"
  local headers2="$out_dir/${prefix}_headers_2.txt"
  gateway_get "$url" "$GATEWAY_HOST" "$body1" "$headers1"
  gateway_get "$url" "$GATEWAY_HOST" "$body2" "$headers2"
  local status1 status2
  status1=$(header_value X-Cache-Status "$headers1" || true)
  status2=$(header_value X-Cache-Status "$headers2" || true)
  if grep -q "\"service\": \"$expect_service\"" "$body2" && \
     grep -q "X-ML-Gateway: $expect_header" "$headers2" && \
     [ "$status1" = MISS ] && [ "$status2" = HIT ]; then
    printf 'CACHE_PAIR_OK=1 route=%s first=%s second=%s\n' "$route" "$status1" "$status2"
    return 0
  fi
  printf 'CACHE_PAIR_OK=0 route=%s first=%s second=%s\n' "$route" "${status1:-missing}" "${status2:-missing}"
  return 1
}

backend_count() {
  local port=$1
  curl -fsS --max-time 3 "http://127.0.0.1:$port/metrics" 2>/dev/null | awk '/^request_count / {print $2; exit}'
}
