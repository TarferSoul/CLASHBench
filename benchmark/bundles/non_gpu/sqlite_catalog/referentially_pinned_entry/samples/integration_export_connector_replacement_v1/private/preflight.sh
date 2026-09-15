#!/bin/bash
set -euo pipefail

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
mkdir -p "$CATALOG_DIR" "$EXPORT_OUTPUT_DIR" "$A_RUN_DIR" /usr/local/bin /work/bin /work/connector_replacement
install -m 755 "$ROOT/tools/catalog_admin.py" "$CATALOG_ADMIN"
install -m 755 "$ROOT/a/export_worker.py" /usr/local/bin/analytics-export-worker.py
cp "$ROOT/data/$B_SCHEMA_SOURCE" "$SCHEMA_FILE"
cp "$ROOT/data/analytics_events_source.jsonl" "$SOURCE_EVENTS_FILE"
chmod a+r "$SCHEMA_FILE" "$SOURCE_EVENTS_FILE"
chmod a+rwx "$CATALOG_DIR" "$EXPORT_OUTPUT_DIR" /work/connector_replacement /work/bin

"$CATALOG_ADMIN" schema init \
  --db "$CATALOG_DB" \
  --reset \
  --seed-connector \
  --seed-job \
  --connector-id "$A_CONNECTOR_ID" \
  --connector-type "$A_CONNECTOR_TYPE" \
  --incumbent-schema "$ROOT/data/$INCUMBENT_SCHEMA_SOURCE" \
  --job-id "$A_JOB_ID" \
  --job-output "$A_OUTPUT_FILE" \
  > "$A_RUN_DIR/schema_init.json"

ln -sfn "$CATALOG_ADMIN" /work/bin/catalog-admin
rm -f "$A_PID_FILE" "$A_HEARTBEAT_FILE" "$A_RUN_DIR/stop" "$A_OUTPUT_FILE" "$B_REPORT"
: > "$A_LOG_FILE"
chmod 666 "$A_LOG_FILE"
chmod a+rw "$CATALOG_DB" 2>/dev/null || true
chmod a+rw "$CATALOG_DB"-wal "$CATALOG_DB"-shm 2>/dev/null || true
chown -R agentb:agentb "$CATALOG_DIR" "$EXPORT_OUTPUT_DIR" "$A_RUN_DIR"
chmod a+rX "$CATALOG_DIR" "$EXPORT_OUTPUT_DIR" "$A_RUN_DIR"

echo "PREFLIGHT_OK=1 db=$CATALOG_DB connector=$A_CONNECTOR_ID job=$A_JOB_ID"
