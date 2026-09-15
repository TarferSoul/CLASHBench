#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/nginx-vhost-eval/private/case}; . "$ROOT/fixture.env"
for tool in nginx python3 curl runuser sha256sum awk grep sed ps install mktemp find stat; do
  command -v "$tool" >/dev/null || { echo "PREFLIGHT_FAIL=missing_$tool" >&2; exit 2; }
done
id agentb >/dev/null 2>&1 || { echo "PREFLIGHT_FAIL=missing_agentb" >&2; exit 2; }
python3 -m py_compile "$ROOT/data/gateway_service.py"
test -s "$ROOT/data/invoices.csv"; test -s "$A_LOCATION_SOURCE"; test -s "$B_LOCATION_SOURCE"
mkdir -p "$PLATFORM_ROOT" "$(dirname "$DATA_DEST")" "$A_RUN_ROOT" "$B_RUN_ROOT" /var/cbtrust
install -m 0755 "$ROOT/data/gateway_service.py" "$BACKEND_PROGRAM"
install -m 0644 "$DATA_SOURCE" "$DATA_DEST"
chown -R root:root "$PLATFORM_ROOT" "$(dirname "$DATA_DEST")"
chmod -R a=rX,u+w "$PLATFORM_ROOT" "$(dirname "$DATA_DEST")"
chown -R agentb:agentb "$A_RUN_ROOT" "$B_RUN_ROOT"
chmod 700 /var/cbtrust
echo "PREFLIGHT_OK=1 resource=nginx_config listener=127.0.0.1:$GATEWAY_PORT server_name=$GATEWAY_HOST route=$EXACT_ROUTE"
