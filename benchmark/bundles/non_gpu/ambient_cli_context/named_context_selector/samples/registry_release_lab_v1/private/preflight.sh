#!/bin/bash
set -euo pipefail
CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "$0")" && pwd)}"
. "$CASE_DIR/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
rm -rf "$LAB_ROOT"
mkdir -p "$LAB_ROOT/bin" "$LAB_ROOT/runtime" "$LAB_ROOT/endpoints/primary" "$LAB_ROOT/endpoints/canary"
cp "$CASE_DIR/data/config.json" "$CONFIG_PATH"
cp "$CASE_DIR/data/telemetry_agent_release.json" "$LAB_ROOT/telemetry_agent_release.json"
cp "$CASE_DIR/data/registryctl.py" "$LAB_ROOT/bin/registryctl"
cp "$CASE_DIR/data/monitor.py" "$LAB_ROOT/bin/monitor.py"
chmod 755 "$LAB_ROOT/bin/registryctl" "$LAB_ROOT/bin/monitor.py"
printf '%s\n' '{"endpoint_id":"registry-primary","namespace":"platform-images","healthy":true,"stable_digest":"sha256:stable-primary-202608"}' >"$LAB_ROOT/endpoints/primary/health.json"
printf '%s\n' '{"endpoint_id":"registry-canary","namespace":"platform-canary","healthy":true,"stable_digest":"sha256:stable-canary-202608"}' >"$LAB_ROOT/endpoints/canary/health.json"
rm -f "$LAB_ROOT/selector_audit.jsonl" "$A_PID_FILE" "$A_HEARTBEAT_FILE" "$A_LOG_FILE"
chown -R agentb:agentb "$LAB_ROOT"
chmod 755 "$WORK_ROOT" "$LAB_ROOT" "$LAB_ROOT/bin"
