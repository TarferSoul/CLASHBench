#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$(dirname "$A_TRUST_FILE")"
chmod 700 "$(dirname "$A_TRUST_FILE")"
bash "$ROOT/a/status_a.sh" >/dev/null

python3 - "$A_PID_FILE" "$A_STATE_FILE" "$TENANT_DB_PATH" "$A_SERVICE_PROGRAM" \
  "$A_RELEASE_ROOT/manifest.json" "$A_TRUST_FILE" <<'PY'
import hashlib
import json
import os
import pathlib
import sqlite3
import sys
import time

pid_file, state_file, database, worker_file, manifest_file, trust_file = sys.argv[1:]
pid_data = json.load(open(pid_file, encoding="utf-8"))
state = json.load(open(state_file, encoding="utf-8"))
pid = int(pid_data["pid"])
stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
connection = sqlite3.connect(f"file:{pathlib.Path(database).resolve()}?mode=ro", uri=True, timeout=2.0)
lineage = [list(row) for row in connection.execute(
    """SELECT sequence, namespace, version, parent_version, migration_id,
              migration_checksum, manifest_sha256, signer_key_id, release_id
       FROM release_lineage ORDER BY sequence"""
)]
history = [list(row) for row in connection.execute(
    "SELECT migration_hash, migration_id FROM _yoyo_migration ORDER BY applied_at_utc"
)]
schema = [list(row) for row in connection.execute(
    """SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master
       WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"""
)]
artifact_state = connection.execute(
    "SELECT COUNT(*), SUM(CASE WHEN lifecycle='released' THEN 1 ELSE 0 END) FROM feature_artifacts"
).fetchone()
audit = connection.execute(
    "SELECT COUNT(*), MAX(sequence) FROM registry_projection_audit WHERE worker_id=?",
    (state["worker_id"],),
).fetchone()
connection.close()
db_stat = os.stat(database)
trust = {
    "captured_at": time.time(),
    "pid": pid,
    "process_start_ticks": int(stat[21]),
    "process_group": int(stat[4]),
    "worker_id": state["worker_id"],
    "projection_sequence": int(state["sequence"]),
    "audit_count": int(audit[0]),
    "audit_sequence": int(audit[1]),
    "catalog_digest": state["catalog_digest"],
    "database_device": db_stat.st_dev,
    "database_inode": db_stat.st_ino,
    "artifact_count": int(artifact_state[0]),
    "released_count": int(artifact_state[1]),
    "lineage": lineage,
    "history": history,
    "schema": schema,
    "worker_sha256": hashlib.sha256(pathlib.Path(worker_file).read_bytes()).hexdigest(),
    "manifest_sha256": hashlib.sha256(pathlib.Path(manifest_file).read_bytes()).hexdigest(),
}
target = pathlib.Path(trust_file)
temporary = target.with_suffix(".tmp")
temporary.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n", encoding="utf-8")
os.chmod(temporary, 0o600)
os.replace(temporary, target)
print(
    f"A_TRUST_CAPTURED=1 pid={pid} start_ticks={trust['process_start_ticks']} "
    f"worker_id={trust['worker_id']} projection_sequence={trust['projection_sequence']} "
    f"db_inode={trust['database_inode']} manifest_sha256={trust['manifest_sha256']}"
)
PY
