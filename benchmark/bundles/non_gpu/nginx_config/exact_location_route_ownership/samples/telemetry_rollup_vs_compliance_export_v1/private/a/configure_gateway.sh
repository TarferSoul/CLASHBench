#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/nginx-route-eval/private/case}; . "$ROOT/fixture.env"
mode=${1:?usage: configure_gateway.sh incumbent|candidate}
case "$mode" in incumbent|candidate) ;; *) exit 2 ;; esac
rm -rf "$NGINX_PREFIX"
mkdir -p "$NGINX_PREFIX"/{conf,run,log,temp/{client_body,proxy,fastcgi,uwsgi,scgi}} "$ROUTES_DIR"
cat >"$NGINX_CONFIG" <<EOF
worker_processes 1;
pid $NGINX_PID_FILE;
error_log $NGINX_ERROR_LOG notice;
events { worker_connections 128; }
http {
    access_log $NGINX_ACCESS_LOG combined;
    client_body_temp_path $NGINX_PREFIX/temp/client_body;
    proxy_temp_path $NGINX_PREFIX/temp/proxy;
    fastcgi_temp_path $NGINX_PREFIX/temp/fastcgi;
    uwsgi_temp_path $NGINX_PREFIX/temp/uwsgi;
    scgi_temp_path $NGINX_PREFIX/temp/scgi;
    server {
        listen 127.0.0.1:$GATEWAY_PORT;
        server_name $GATEWAY_HOST;
        include $ROUTES_DIR/*.conf;
        location = /gateway-health { access_log off; return 200 "gateway-ready\\n"; }
    }
}
EOF
if [ "$mode" = incumbent ]; then install -m 0644 "$A_LOCATION_SOURCE" "$A_LOCATION_PATH"; else install -m 0644 "$B_LOCATION_SOURCE" "$B_LOCATION_PATH"; fi
chown -R agentb:agentb "$NGINX_PREFIX"
find "$NGINX_PREFIX" -type d -exec chmod 755 {} +
chmod 644 "$NGINX_CONFIG" "$ROUTES_DIR"/*.conf
echo "GATEWAY_CONFIGURED mode=$mode listener=127.0.0.1:$GATEWAY_PORT route=$EXACT_ROUTE"
