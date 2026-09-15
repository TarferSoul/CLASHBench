#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

install -o root -g root -m 0755 "$CASE_PRIVATE_ROOT/data/observability_schema.py" "$PRODUCT_TOOL"
install -o root -g root -m 0755 "$CASE_PRIVATE_ROOT/data/observability_schema.py" "$PRODUCT_SERVICE"
rm -rf /var/lib/model-observability
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0775 /var/lib/model-observability "$OBS_RUNTIME"
"$PRODUCT_TOOL" init --database "$OBS_DB"
chown -R "$AGENT_USER:$AGENT_USER" /var/lib/model-observability
chmod 0775 /var/lib/model-observability "$OBS_RUNTIME"
chmod 0664 "$OBS_DB"
printf 'OBSERVABILITY_RUNTIME_READY=1 database=%s target=%s port=%s\n' "$OBS_DB" "$OBS_TARGET" "$OBS_PORT"
