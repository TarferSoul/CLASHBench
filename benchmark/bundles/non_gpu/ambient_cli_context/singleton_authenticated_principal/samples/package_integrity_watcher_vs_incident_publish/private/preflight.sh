#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1090
. "$PRIVATE_ROOT/fixture.env"

command -v python3 >/dev/null
id agentb >/dev/null 2>&1

install -d -m 0711 "$SERVICE_RUNTIME_DIR"
install -d -m 0700 "$SERVICE_STATE_ROOT"
install -m 0700 "$PRIVATE_ROOT/data/$SERVER_SCRIPT" "$SERVICE_RUNTIME_DIR/$SERVER_SCRIPT"
install -m 0755 "$PRIVATE_ROOT/data/$CLI_SCRIPT" "/usr/local/bin/$CLI_NAME"
install -m 0755 "$PRIVATE_ROOT/a/$A_WORKER_SCRIPT" "$SERVICE_RUNTIME_DIR/$A_WORKER_SCRIPT"

install -d -o agentb -g agentb -m 0755 "$SHARED_CONFIG_DIR"
install -o agentb -g agentb -m 0600 "$PRIVATE_ROOT/data/$INITIAL_STORE" "$SHARED_CONFIG_FILE"
rm -rf "$A_RUNTIME_ROOT"
install -d -o agentb -g agentb -m 0755 "$A_RUNTIME_ROOT"

install -d -o agentb -g agentb -m 0755 /work
install -o agentb -g agentb -m 0644 "$PRIVATE_ROOT/data/$PUBLIC_FILE_1" "/work/$PUBLIC_FILE_1"
install -o agentb -g agentb -m 0644 "$PRIVATE_ROOT/data/$PUBLIC_FILE_2" "/work/$PUBLIC_FILE_2"
install -o agentb -g agentb -m 0644 "$PRIVATE_ROOT/data/$PUBLIC_FILE_3" "/work/$PUBLIC_FILE_3"

rm -f "$SERVICE_RUNTIME_DIR/service.pid" "$SERVICE_RUNTIME_DIR/service.log" "$TRUST_FILE"
printf 'PREFLIGHT_OK=1 case=package_integrity_watcher_vs_incident_publish store=%s\n' "$SHARED_CONFIG_FILE"
