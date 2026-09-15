#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$A_PID_FILE" "$A_STATE_FILE" "$TENANT_DB_PATH" \
  "$A_HEARTBEAT_MAX_AGE_SECONDS" "$A_RELEASE_ID" "$A_TARGET_CHECKSUM" <<'PY'
import json
import os
import pathlib
import sqlite3
import sys
import time

pid_file, state_file, database, max_age, release_id, checksum = sys.argv[1:]

def fail(reason, **details):
    suffix = " ".join(f"{key}={value}" for key, value in details.items())
    print(f"A_READY=0 reason={reason}" + (" " + suffix if suffix else ""))
    raise SystemExit(1)

try:
    pid_data = json.load(open(pid_file, encoding="utf-8"))
    state = json.load(open(state_file, encoding="utf-8"))
    pid = int(pid_data["pid"])
    os.kill(pid, 0)
    process = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
except Exception as exc:
    fail("worker_state_unavailable", detail=type(exc).__name__)
if process[2] in {"T", "t", "Z", "X"}:
    fail("worker_not_runnable", state=process[2])
connection = sqlite3.connect(f"file:{pathlib.Path(database).resolve()}?mode=ro", uri=True, timeout=2.0)
current = connection.execute(
    "SELECT version, migration_checksum, release_id FROM release_lineage ORDER BY sequence DESC LIMIT 1"
).fetchone()
columns = {row[1] for row in connection.execute("PRAGMA table_info(feature_artifacts)")}
audit = connection.execute(
    "SELECT COUNT(*), MAX(sequence) FROM registry_projection_audit WHERE worker_id=?",
    (pid_data["worker_id"],),
).fetchone()
connection.close()
checks = {
    "worker_identity": state.get("worker_id") == pid_data.get("worker_id"),
    "healthy": state.get("healthy") is True,
    "heartbeat": time.time() - float(state.get("heartbeat_at", 0)) <= float(max_age),
    "lineage": current == ("M307", checksum, release_id),
    "schema": "validation_state" in columns and "provenance_digest" not in columns,
    "progress": int(state.get("sequence", 0)) >= 1 and int(audit[0]) >= 1 and int(audit[1] or 0) >= 1,
}
if not all(checks.values()):
    fail("worker_contract_failed", checks=",".join(key for key, ok in checks.items() if not ok))
print(
    f"A_READY=1 pid={pid} worker_id={state['worker_id']} release={release_id} "
    f"version=M307 checksum={checksum} projection_sequence={state['sequence']} "
    f"artifacts={state['artifact_count']} catalog_digest={state['catalog_digest']}"
)
PY
