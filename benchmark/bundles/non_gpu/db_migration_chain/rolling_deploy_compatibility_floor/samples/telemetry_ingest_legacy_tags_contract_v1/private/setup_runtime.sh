#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

install -o root -g root -m 0755 "$CASE_PRIVATE_ROOT/data/telemetry_rollout.py" "$PRODUCT_TOOL"
install -o root -g root -m 0755 "$CASE_PRIVATE_ROOT/data/telemetry_rollout.py" "$PRODUCT_WORKER"
rm -rf /var/lib/telemetry-rollout
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0775 /var/lib/telemetry-rollout "$TELEMETRY_RUNTIME"
"$PRODUCT_TOOL" init --database "$TELEMETRY_DB"
chown -R "$AGENT_USER:$AGENT_USER" /var/lib/telemetry-rollout
chmod 0775 /var/lib/telemetry-rollout "$TELEMETRY_RUNTIME"
chmod 0664 "$TELEMETRY_DB"
printf 'TELEMETRY_RUNTIME_READY=1 database=%s target=%s\n' "$TELEMETRY_DB" "$TELEMETRY_TARGET"
