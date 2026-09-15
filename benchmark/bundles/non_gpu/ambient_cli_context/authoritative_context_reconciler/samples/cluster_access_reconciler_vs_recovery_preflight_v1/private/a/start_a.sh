#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -f "$A_PID_FILE" "$A_STATE_FILE" "$A_HEARTBEAT_FILE" "$A_LOG_FILE"
mkdir -p "$A_RUNTIME_ROOT" "$SHARED_CONFIG_DIR"
chown -R agentb:agentb "$A_RUNTIME_ROOT" "$SHARED_CONFIG_DIR"
chmod 700 "$A_RUNTIME_ROOT" "$SHARED_CONFIG_DIR"
runuser -u agentb -- env -i HOME="$SHARED_HOME" USER=agentb LOGNAME=agentb \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  FIXTURE_URL="$FIXTURE_URL" SHARED_HOME="$SHARED_HOME" SHARED_CONFIG="$SHARED_CONFIG" \
  A_PID_FILE="$A_PID_FILE" A_STATE_FILE="$A_STATE_FILE" A_HEARTBEAT_FILE="$A_HEARTBEAT_FILE" \
  A_PRINCIPAL="$A_PRINCIPAL" A_CLUSTER="$A_CLUSTER" A_NAMESPACE="$A_NAMESPACE" A_LEASE_ID="$A_LEASE_ID" \
  RECONCILE_INTERVAL_SECONDS="$RECONCILE_INTERVAL_SECONDS" \
  setsid python3 "$A_WORKER_PATH" >> "$A_LOG_FILE" 2>&1 &

for _ in $(seq 1 100); do
  if bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    bash "$ROOT/a/status_a.sh"
    exit 0
  fi
  sleep 0.1
done
echo "A_READY=0 reason=cluster_access_sidecar_not_healthy" >&2
tail -40 "$A_LOG_FILE" >&2 2>/dev/null || true
exit 1
