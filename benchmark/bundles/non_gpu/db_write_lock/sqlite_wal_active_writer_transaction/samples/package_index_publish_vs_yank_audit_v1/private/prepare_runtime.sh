#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
mkdir -p "$DB_DIR" "$A_RUNTIME_ROOT"
python3 "$CASE_PRIVATE_ROOT/data/prepare_db.py" "$DB_PATH"
install -o agentb -g agentb -m 500 "$CASE_PRIVATE_ROOT/data/index_builder.py" "$A_WORKER_RUNTIME"
rm -f "$A_STATUS_FILE" "$A_LOG_FILE"
chown -R agentb:agentb "$DB_DIR" "$A_RUNTIME_ROOT"
chmod 700 "$DB_DIR" "$A_RUNTIME_ROOT"
chmod 600 "$DB_PATH"
