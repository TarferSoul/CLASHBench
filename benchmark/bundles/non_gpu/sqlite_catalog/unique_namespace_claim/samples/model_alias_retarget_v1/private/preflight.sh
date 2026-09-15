#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
mkdir -p "$CATALOG_DIR/requests" "$A_RUN_DIR" "$A_RUNTIME_DIR" /usr/local/bin
install -m 755 "$ROOT/data/$CLI_SOURCE" "/usr/local/bin/$CLI_NAME"
cp "$ROOT/a/model_serving_gateway.py" "$A_RUNTIME_PROGRAM"
cp "$ROOT/data/embed_requests.json" "$MODEL_REQUEST_FILE"
cp "$ROOT/data/model_health.json" "$CATALOG_DIR/model_health.json"
chown -R agentb:agentb "$A_RUNTIME_DIR" "$CATALOG_DIR" "$A_RUN_DIR"
chmod -R a+rx "$A_RUNTIME_DIR"
chmod a+rwx "$CATALOG_DIR" "$CATALOG_DIR/requests" "$A_RUN_DIR"
chmod a+r "$MODEL_REQUEST_FILE" "$CATALOG_DIR/model_health.json"

"/usr/local/bin/$CLI_NAME" schema init --db "$CATALOG_DB" --reset --seed-incumbent \
  --request-file "$MODEL_REQUEST_FILE" > "$A_RUN_DIR/schema_init.json"
chmod 666 "$CATALOG_DB"
rm -f "$A_PID_FILE" "$A_HEARTBEAT_FILE" "$A_RUN_DIR/stop"
: > "$A_LOG_FILE"
chmod 666 "$A_LOG_FILE"

if [ -d /work ]; then
  mkdir -p /work/bin /work/model_registration
  ln -sfn "/usr/local/bin/$CLI_NAME" "/work/bin/$CLI_NAME"
  chmod 755 /work/bin /work/model_registration
fi

echo "PREFLIGHT_OK=1 db=$CATALOG_DB alias=$A_TENANT/$A_ALIAS model=$A_MODEL_ID"
