#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
mkdir -p "$CATALOG_DIR/requests" "$CATALOG_DIR/models" "$A_RUN_DIR" "$A_RUNTIME_DIR" /var/log/inference-route-service
install -m 755 "$ROOT/data/$CLI_SOURCE" "/usr/local/bin/$CLI_NAME"
install -m 755 "$ROOT/a/route_gateway.py" "$A_RUNTIME_PROGRAM"
cp "$ROOT/data/embed_batch.json" "$A_REQUEST_FILE"
cp "$ROOT/data/embedder_prod_v1_health.json" "$A_HEALTH_FILE"
chown -R agentb:agentb "$CATALOG_DIR" "$A_RUN_DIR" /var/log/inference-route-service
chmod 770 "$CATALOG_DIR" "$CATALOG_DIR/requests" "$CATALOG_DIR/models" "$A_RUN_DIR" /var/log/inference-route-service
chmod 664 "$A_REQUEST_FILE" "$A_HEALTH_FILE"

"/usr/local/bin/$CLI_NAME" schema init --db "$CATALOG_DB" --reset --seed-incumbent --request-file "$A_REQUEST_FILE" --health-file "$A_HEALTH_FILE" > "$A_RUN_DIR/schema_init.json"
chown agentb:agentb "$CATALOG_DB"
chmod 660 "$CATALOG_DB"
for sidecar in "$CATALOG_DB-wal" "$CATALOG_DB-shm"; do
  if [ -e "$sidecar" ]; then
    chown agentb:agentb "$sidecar"
    chmod 660 "$sidecar"
  fi
done
rm -f "$A_PID_FILE" "$A_LAUNCHER_FILE" "$A_HEARTBEAT_FILE" "$A_RUN_DIR/stop" "$A_LOG_FILE" "$A_TRUST_FILE"
: > "$A_LOG_FILE"
chown agentb:agentb "$A_LOG_FILE"
chmod 660 "$A_LOG_FILE"

if [ -d /work ]; then
  mkdir -p /work/route_reassignment /work/output /work/bin
  ln -sfn "/usr/local/bin/$CLI_NAME" "/work/bin/$CLI_NAME"
  chown -R agentb:agentb /work
  chmod 755 /work /work/route_reassignment /work/output /work/bin
fi

echo "PREFLIGHT_OK=1 db=$CATALOG_DB key=$ROUTE_KEY incumbent=$A_TARGET"
