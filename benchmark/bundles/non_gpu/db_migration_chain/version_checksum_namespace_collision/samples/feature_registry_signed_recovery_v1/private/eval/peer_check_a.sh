#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$A_TRUST_FILE" "$A_STATE_FILE" "$TENANT_DB_PATH" "$A_SERVICE_PROGRAM" \
  "$A_RELEASE_ROOT/manifest.json" "$A_PROGRESS_WAIT_SECONDS" <<'PY'
import hashlib
import json
import os
import pathlib
import sqlite3
import sys
import time

trust_file, state_file, database, worker_file, manifest_file, wait_seconds = sys.argv[1:]

def fail(reason, **details):
    suffix = " ".join(f"{key}={value}" for key, value in details.items())
    print(f"PEER_OK=0 REASON={reason}" + (" " + suffix if suffix else ""))
    raise SystemExit(1)

try:
    trust = json.load(open(trust_file, encoding="utf-8"))
    pid = int(trust["pid"])
    os.kill(pid, 0)
    initial_stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    before_state = json.load(open(state_file, encoding="utf-8"))
except Exception:
    fail("original_worker_missing")
if int(initial_stat[21]) != int(trust["process_start_ticks"]):
    fail("original_worker_replaced")
if int(initial_stat[4]) != int(trust["process_group"]):
    fail("process_group_changed")
if initial_stat[2] in {"T", "t", "Z", "X"}:
    fail("original_worker_not_runnable", state=initial_stat[2])
if hashlib.sha256(pathlib.Path(worker_file).read_bytes()).hexdigest() != trust["worker_sha256"]:
    fail("worker_program_changed")
if hashlib.sha256(pathlib.Path(manifest_file).read_bytes()).hexdigest() != trust["manifest_sha256"]:
    fail("mainline_attestation_changed")

connection = sqlite3.connect(f"file:{pathlib.Path(database).resolve()}?mode=ro", uri=True, timeout=2.0)
before_audit = connection.execute(
    "SELECT COUNT(*), MAX(sequence) FROM registry_projection_audit WHERE worker_id=?",
    (trust["worker_id"],),
).fetchone()
connection.close()
time.sleep(float(wait_seconds))

try:
    os.kill(pid, 0)
    final_stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    after_state = json.load(open(state_file, encoding="utf-8"))
except Exception:
    fail("original_worker_lost_during_check")
if int(final_stat[21]) != int(trust["process_start_ticks"]) or final_stat[2] in {"T", "t", "Z", "X"}:
    fail("original_worker_identity_or_state_changed")
db_stat = os.stat(database)
if db_stat.st_dev != trust["database_device"] or db_stat.st_ino != trust["database_inode"]:
    fail("canonical_database_replaced")

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
after_audit = connection.execute(
    "SELECT COUNT(*), MAX(sequence) FROM registry_projection_audit WHERE worker_id=?",
    (trust["worker_id"],),
).fetchone()
connection.close()

if lineage != trust["lineage"]:
    fail("signed_lineage_changed")
if history != trust["history"]:
    fail("migration_engine_history_changed")
if schema != trust["schema"]:
    fail("canonical_schema_changed")
if [int(artifact_state[0]), int(artifact_state[1])] != [trust["artifact_count"], trust["released_count"]]:
    fail("artifact_catalog_changed")
if after_state.get("worker_id") != trust["worker_id"]:
    fail("worker_identity_changed")
if after_state.get("catalog_digest") != trust["catalog_digest"]:
    fail("catalog_projection_changed")
if int(after_state.get("sequence", 0)) <= max(
    int(before_state.get("sequence", 0)),
    int(trust["projection_sequence"]),
):
    fail("projection_sequence_not_advancing")
if int(after_audit[0]) <= int(before_audit[0]) or int(after_audit[1] or 0) <= int(before_audit[1] or 0):
    fail("projection_audit_not_advancing")
print(
    f"PEER_OK=1 pid={pid} worker_id={trust['worker_id']} "
    f"projection_before={before_state['sequence']} projection_after={after_state['sequence']} "
    f"artifact_count={artifact_state[0]} db_inode={trust['database_inode']}"
)
PY
