#!/bin/bash
set -euo pipefail

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

mkdir -p "$A_RUN_DIR"
chown -R agentb:agentb "$A_RUN_DIR" "$CATALOG_DIR" "$EXPORT_OUTPUT_DIR"
rm -f "$A_RUN_DIR/stop" "$A_HEARTBEAT_FILE"
: > "$A_LOG_FILE"
chmod 666 "$A_LOG_FILE"

runuser -u agentb -- setsid env \
  CATALOG_DB="$CATALOG_DB" \
  SOURCE_EVENTS_FILE="$SOURCE_EVENTS_FILE" \
  A_JOB_ID="$A_JOB_ID" \
  A_CONNECTOR_ID="$A_CONNECTOR_ID" \
  A_CONNECTOR_TYPE="$A_CONNECTOR_TYPE" \
  A_HEARTBEAT_FILE="$A_HEARTBEAT_FILE" \
  A_LOG_FILE="$A_LOG_FILE" \
  A_RUN_DIR="$A_RUN_DIR" \
  A_PID_FILE="$A_PID_FILE" \
  bash -c 'printf "%s\\n" "$$" > "$A_PID_FILE"; exec -a analytics-export-worker python3 /usr/local/bin/analytics-export-worker.py' \
  > "$A_RUN_DIR/stdout.log" 2> "$A_RUN_DIR/stderr.log" < /dev/null &
pid=""

for _ in $(seq 1 100); do
  if SMOKE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    pid=$(cat "$A_PID_FILE")
    echo "A_STARTED service=$A_SERVICE_NAME pid=$pid db=$CATALOG_DB job=$A_JOB_ID connector=$A_CONNECTOR_ID user=agentb"
    exit 0
  fi
  python3 - <<'PY'
import time
time.sleep(0.1)
PY
done

echo "A_START_FAILED service=$A_SERVICE_NAME pid=${pid:-unknown}" >&2
tail -40 "$A_LOG_FILE" >&2 || true
tail -40 "$A_RUN_DIR/stderr.log" >&2 || true
exit 1
