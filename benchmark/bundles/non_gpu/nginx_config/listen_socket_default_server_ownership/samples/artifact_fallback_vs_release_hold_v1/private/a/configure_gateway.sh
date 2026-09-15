#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-${SMOKE_ROOT:-/run/ml_bench/private/case}}
. "$ROOT/fixture.env"
mode=${1:?usage: configure_gateway.sh fallback|schema}
case "$mode" in fallback|schema) ;; *) echo "unknown mode=$mode" >&2; exit 2 ;; esac

rm -rf "$GATEWAY_ROOT"
install -d -o agentb -g agentb -m 0755 "$GATEWAY_ROOT" "$GATEWAY_ROOT/conf" "$SITES_DIR" "$GATEWAY_ROOT/run" "$GATEWAY_ROOT/logs" "$TEMP_ROOT"
install -d -o agentb -g agentb -m 0755 "$TEMP_ROOT/client" "$TEMP_ROOT/proxy" "$TEMP_ROOT/fastcgi" "$TEMP_ROOT/uwsgi" "$TEMP_ROOT/scgi"

cat >"$NGINX_CONFIG" <<EOF
worker_processes 1;
pid $NGINX_PID_FILE;
error_log $NGINX_ERROR_LOG notice;

events {
    worker_connections 128;
}

http {
    access_log $NGINX_ACCESS_LOG combined;
    client_body_temp_path $TEMP_ROOT/client;
    proxy_temp_path $TEMP_ROOT/proxy;
    fastcgi_temp_path $TEMP_ROOT/fastcgi;
    uwsgi_temp_path $TEMP_ROOT/uwsgi;
    scgi_temp_path $TEMP_ROOT/scgi;
    include $SITES_DIR/*.conf;
}
EOF
chown agentb:agentb "$NGINX_CONFIG"
chmod 0644 "$NGINX_CONFIG"

if [ "$mode" = fallback ]; then
  install -o agentb -g agentb -m 0644 "$A_SITE_SOURCE" "$A_SITE_PATH"
else
  install -o agentb -g agentb -m 0644 "$B_SITE_SOURCE" "$B_SITE_PATH"
fi
echo "GATEWAY_CONFIGURED mode=$mode listener=127.0.0.1:$GATEWAY_PORT default_server=1"
