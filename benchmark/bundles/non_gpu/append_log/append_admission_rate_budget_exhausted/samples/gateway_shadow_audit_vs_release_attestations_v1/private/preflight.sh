#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
. "$ROOT/fixture.env"

bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -rf "$RUNTIME_DIR" "$A_RUNTIME"
install -d -o root -g root -m 700 "$RUNTIME_DIR" "$PRIVATE_STATE" "$FIXTURE_DIR" "$PID_DIR" "$LOG_DIR"
install -d -o agentb -g agentb -m 755 "$A_RUNTIME"
python3 "$ROOT/data/materialize.py" --fixture-dir "$FIXTURE_DIR" --token-file "$TOKEN_FILE" --a-runtime "$A_RUNTIME"
install -o agentb -g agentb -m 755 "$ROOT/a/gateway_shadow_publisher.py" "$A_RUNTIME/gateway_shadow_publisher.py"
install -o agentb -g agentb -m 600 "$TOKEN_FILE" "$A_TOKEN"
chown agentb:agentb "$A_ROUTES"
chmod 600 "$A_ROUTES"
chmod -R go-rwx "$PRIVATE_STATE"
echo "PREFLIGHT_OK=1 protocol=http fixture_records=$B_TOTAL_RECORDS a_runtime=$A_RUNTIME"
