#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
command -v evalboard-admin >/dev/null

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
test -x "$A_PROGRAM"

mkdir -p /run/lock /run/evalboard "$STATE_DIR" "$INCOMING_DIR" "$PROCESSED_DIR" "$FIXTURE_DIR" "$RESCORE_OUTPUT_DIR"
touch "$LOCK_PATH"
chmod 0666 "$LOCK_PATH"
chown -R "$A_SERVICE_USER:$A_SERVICE_USER" /run/evalboard
chown -R agentb:agentb "$STATE_DIR" "$INCOMING_DIR" "$PROCESSED_DIR" "$RESCORE_OUTPUT_DIR"
chmod 0777 "$STATE_DIR" "$INCOMING_DIR" "$PROCESSED_DIR"
chmod 0755 "$FIXTURE_DIR" "$RESCORE_OUTPUT_DIR"

test -f "$BASELINE_INPUT"
test -f "$RESCORE_INPUT"
test -f "$DB_PATH"

python3 - "$LOCK_PATH" "$DB_PATH" <<'PY'
import os
import pathlib
import sqlite3
import sys

lock_path, db_path = sys.argv[1:]
st = os.stat(lock_path)
conn = sqlite3.connect(db_path)
try:
    tables = {
        row[0]
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
    }
finally:
    conn.close()
required = {"metadata", "result_records", "rescore_runs"}
missing = sorted(required - tables)
if missing:
    raise SystemExit(f"missing sqlite tables: {','.join(missing)}")
print(
    "PREFLIGHT_OK=1 "
    f"lock_device_major={os.major(st.st_dev)} lock_device_minor={os.minor(st.st_dev)} "
    f"lock_inode={st.st_ino} db={pathlib.Path(db_path)}"
)
PY
