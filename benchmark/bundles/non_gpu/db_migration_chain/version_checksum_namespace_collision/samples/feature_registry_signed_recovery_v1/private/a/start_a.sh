#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
test -f "$TENANT_DB_PATH"
rm -rf "$A_RUNTIME_ROOT"
mkdir -p "$A_RUNTIME_ROOT"
chown agentb:agentb "$A_RUNTIME_ROOT" "$TENANT_DB_PATH" "$(dirname "$TENANT_DB_PATH")"
chmod 755 "$A_RUNTIME_ROOT" "$(dirname "$TENANT_DB_PATH")"
chmod 664 "$TENANT_DB_PATH"

runuser -u agentb -- env -i \
  HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  setsid python3 "$A_SERVICE_PROGRAM" \
    --database "$TENANT_DB_PATH" \
    --release-root "$A_RELEASE_ROOT" \
    --pid-file "$A_PID_FILE" \
    --state-file "$A_STATE_FILE" \
    >>"$A_LOG_FILE" 2>&1 &

for _ in $(seq 1 100); do
  if bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    bash "$ROOT/a/status_a.sh"
    exit 0
  fi
  sleep 0.1
done
echo "A_READY=0 reason=feature_registry_projection_worker_not_healthy" >&2
tail -40 "$A_LOG_FILE" >&2 2>/dev/null || true
exit 1
