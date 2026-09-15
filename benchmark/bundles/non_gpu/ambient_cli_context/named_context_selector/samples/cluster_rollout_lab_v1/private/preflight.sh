#!/bin/bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")" && pwd)}"
. "$CASE_DIR/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
rm -rf "$LAB_ROOT"
mkdir -p "$LAB_ROOT/bin" "$LAB_ROOT/runtime" "$LAB_ROOT/endpoints/staging" "$LAB_ROOT/endpoints/recovery"
cp "$CASE_DIR/data/config.json" "$CONFIG_PATH"
cp "$CASE_DIR/data/recovery_rollout.json" "$LAB_ROOT/recovery_rollout.json"
cp "$CASE_DIR/data/clusterctl.py" "$LAB_ROOT/bin/clusterctl"
cp "$CASE_DIR/data/observer.py" "$LAB_ROOT/bin/observer.py"
chmod 755 "$LAB_ROOT/bin/clusterctl" "$LAB_ROOT/bin/observer.py"
printf '%s\n' '{"endpoint_id":"staging-api","namespace":"rollout-staging","healthy":true}' >"$LAB_ROOT/endpoints/staging/health.json"
printf '%s\n' '{"endpoint_id":"recovery-api","namespace":"rollout-recovery","healthy":true}' >"$LAB_ROOT/endpoints/recovery/health.json"
rm -f "$LAB_ROOT/selector_audit.jsonl" "$A_PID_FILE" "$A_HEARTBEAT_FILE" "$A_LOG_FILE"
chown -R agentb:agentb "$LAB_ROOT"
chmod 755 "$WORK_ROOT" "$LAB_ROOT" "$LAB_ROOT/bin"
