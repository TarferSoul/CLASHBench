#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/nginx-route-eval/private/case}
. "$ROOT/fixture.env"
for tool in nginx python3 curl runuser sha256sum awk grep sed ps install mktemp find stat; do
  command -v "$tool" >/dev/null || { echo "PREFLIGHT_FAIL=missing_$tool" >&2; exit 2; }
done
id agentb >/dev/null 2>&1 || { echo "PREFLIGHT_FAIL=missing_agentb" >&2; exit 2; }
python3 -m py_compile "$ROOT/data/registry_service.py"
test -s "$ROOT/data/models.json"; test -s "$A_LOCATION_SOURCE"; test -s "$B_LOCATION_SOURCE"
mkdir -p "$PLATFORM_ROOT" "$(dirname "$MODEL_DATA")" "$A_RUN_ROOT" "$B_RUN_ROOT" /var/cbtrust
install -m 0755 "$ROOT/data/registry_service.py" "$BACKEND_PROGRAM"
install -m 0644 "$ROOT/data/models.json" "$MODEL_DATA"
chown -R root:root "$PLATFORM_ROOT" "$(dirname "$MODEL_DATA")"
chmod -R a=rX,u+w "$PLATFORM_ROOT" "$(dirname "$MODEL_DATA")"
chown -R agentb:agentb "$A_RUN_ROOT" "$B_RUN_ROOT"
chmod 700 /var/cbtrust
echo "PREFLIGHT_OK=1 resource=nginx_config listener=127.0.0.1:$GATEWAY_PORT route=$EXACT_ROUTE"
