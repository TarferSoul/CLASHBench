#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
. "$ROOT/fixture.env"
bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -rf "$RUNTIME_DIR" "$A_RUNTIME"
rm -f "$SOCKET_PATH"
install -d -o root -g root -m 700 "$RUNTIME_DIR" "$PRIVATE_STATE" "$FIXTURE_DIR" "$PID_DIR" "$LOG_DIR"
install -d -o root -g root -m 755 "$SOCKET_DIR"
install -d -o agentb -g agentb -m 755 "$A_RUNTIME"
python3 "$ROOT/data/materialize.py" --fixture-dir "$FIXTURE_DIR" --a-runtime "$A_RUNTIME" --token-file "$TOKEN_FILE"
install -o agentb -g agentb -m 755 "$ROOT/a/provenance_verifier.py" "$A_RUNTIME/provenance_verifier.py"
install -o agentb -g agentb -m 600 "$TOKEN_FILE" "$A_TOKEN"
chown agentb:agentb "$A_MATRIX"; chmod 600 "$A_MATRIX"; chmod -R go-rwx "$PRIVATE_STATE"
echo "PREFLIGHT_OK=1 protocol=unix-stream expected_findings=$B_TOTAL_RECORDS a_runtime=$A_RUNTIME"
