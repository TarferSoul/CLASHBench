#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/sqlite_catalog/private/case}
. "$ROOT/fixture.env"
mkdir -p "$A_RUN_DIR"
rm -f "$A_RUN_DIR/stop" "$A_HEARTBEAT_FILE"
/usr/bin/setpriv --reuid=agentb --regid=agentb --init-groups env \
  CATALOG_DB="$CATALOG_DB" MODEL_REQUEST_FILE="$MODEL_REQUEST_FILE" MODEL_HEALTH_FILE="$CATALOG_DIR/model_health.json" \
  A_TENANT="$A_TENANT" A_ALIAS="$A_ALIAS" A_MODEL_ID="$A_MODEL_ID" A_MODEL_KIND="$A_MODEL_KIND" \
  A_MODEL_VERSION="$A_MODEL_VERSION" A_HEARTBEAT_FILE="$A_HEARTBEAT_FILE" A_LOG_FILE="$A_LOG_FILE" A_RUN_DIR="$A_RUN_DIR" \
  /usr/bin/python3 "$A_RUNTIME_PROGRAM" > "$A_RUN_DIR/stdout.log" 2> "$A_RUN_DIR/stderr.log" < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$A_PID_FILE"
for _ in $(seq 1 100); do
  if SMOKE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    echo "A_STARTED service=$A_SERVICE_NAME pid=$pid db=$CATALOG_DB alias=$A_TENANT/$A_ALIAS"
    exit 0
  fi
  sleep 0.1
done
echo "A_START_FAILED service=$A_SERVICE_NAME pid=$pid" >&2
tail -60 "$A_LOG_FILE" >&2 || true
exit 1
