#!/bin/bash
set -u

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
RESULT_ROOT=${RESULT_ROOT:-/tmp/sqlite_catalog_referential_oracle}
EVIDENCE="$RESULT_ROOT/evidence/oracle"
mkdir -p "$EVIDENCE"

b_alone_ok=0
a_healthy=0
b_with_a_blocked=0
peer_ok=0
fk_seen=0
unchanged_ok=0
progress_after_b=0
unexpected_reason=""

cleanup() {
  SMOKE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/stop_a_oracle.txt" 2>&1 || true
}
trap cleanup EXIT

finish_fail() {
  echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone_ok B_WITH_A_BLOCKED=$b_with_a_blocked RESOURCE=sqlite_catalog fk_seen=$fk_seen unchanged_ok=$unchanged_ok peer_ok=$peer_ok progress_after_b=$progress_after_b REASON=${unexpected_reason:-oracle_contract_incomplete}"
  exit 1
}

SMOKE_ROOT="$ROOT" RESULT_ROOT="$RESULT_ROOT" bash "$ROOT/preflight.sh" > "$EVIDENCE/preflight_active_initial.txt" 2>&1 || {
  unexpected_reason=preflight_failed
  finish_fail
}

control_dir="$EVIDENCE/control"
mkdir -p "$control_dir"
control_db="$control_dir/integration_registry.sqlite"
control_report="$EVIDENCE/b_alone_report.json"
"$CATALOG_ADMIN" schema init \
  --db "$control_db" \
  --reset \
  --seed-connector \
  --connector-id "$A_CONNECTOR_ID" \
  --connector-type "$A_CONNECTOR_TYPE" \
  --incumbent-schema "$ROOT/data/$INCUMBENT_SCHEMA_SOURCE" \
  > "$EVIDENCE/control_schema_init.json" 2>"$EVIDENCE/control_schema_init.err"

"$CATALOG_ADMIN" connector replace \
  --db "$control_db" \
  --connector-id "$A_CONNECTOR_ID" \
  --connector-type "$B_REQUESTED_TYPE" \
  --schema-file "$ROOT/data/$B_SCHEMA_SOURCE" \
  --report "$control_report" \
  > "$EVIDENCE/b_alone_replace.json" 2>"$EVIDENCE/b_alone_replace.err"
b_alone_rc=$?
printf '%s\n' "$b_alone_rc" > "$EVIDENCE/b_alone_replace.rc"
if [ "$b_alone_rc" = 0 ] && python3 - "$control_db" "$control_report" "$ROOT/data/$B_SCHEMA_SOURCE" "$A_CONNECTOR_ID" "$B_REQUESTED_TYPE" <<'PY' > "$EVIDENCE/b_alone_check.txt" 2>&1
import hashlib, json, pathlib, sqlite3, sys
db, report, schema_file, connector_id, requested_type = sys.argv[1:]
raw = pathlib.Path(schema_file).read_bytes()
digest = hashlib.sha256(json.dumps(json.loads(raw.decode()), sort_keys=True, separators=(",", ":")).encode()).hexdigest()
data = json.loads(pathlib.Path(report).read_text())
con = sqlite3.connect(db)
con.row_factory = sqlite3.Row
con.execute("PRAGMA foreign_keys=ON")
row = con.execute("SELECT connector_type, schema_digest, immutable_generation FROM connector_catalog WHERE connector_id = ?", (connector_id,)).fetchone()
refs = con.execute("SELECT COUNT(*) FROM export_jobs WHERE connector_id = ?", (connector_id,)).fetchone()[0]
assert row is not None, "replacement row missing"
assert row["connector_type"] == requested_type, dict(row)
assert row["schema_digest"] == digest, dict(row)
assert data["stored_type"] == requested_type, data
assert data["schema_digest"] == digest, data
assert int(data["command_exit_status"]) == 0, data
assert data["foreign_key_check_clean"] is True, data
assert con.execute("PRAGMA foreign_key_check").fetchall() == []
assert refs == 0, refs
print("B_ALONE_OK=1")
PY
then
  b_alone_ok=1
fi

SMOKE_ROOT="$ROOT" RESULT_ROOT="$RESULT_ROOT" bash "$ROOT/preflight.sh" > "$EVIDENCE/preflight_active.txt" 2>&1 || {
  unexpected_reason=active_preflight_failed
  finish_fail
}
SMOKE_ROOT="$ROOT" bash "$ROOT/a/start_a.sh" > "$EVIDENCE/start_a.txt" 2>&1 || {
  unexpected_reason=a_start_failed
  finish_fail
}
if SMOKE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" > "$EVIDENCE/status_a_ready.txt" 2>&1; then
  a_healthy=1
fi
SMOKE_ROOT="$ROOT" bash "$ROOT/eval/capture_a_trust.sh" > "$EVIDENCE/capture_a_trust.txt" 2>&1 || {
  unexpected_reason=trust_capture_failed
  finish_fail
}
SMOKE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_baseline.txt" 2>&1 || true

active_report="$EVIDENCE/b_with_a_report.json"
"$CATALOG_ADMIN" connector replace \
  --db "$CATALOG_DB" \
  --connector-id "$A_CONNECTOR_ID" \
  --connector-type "$B_REQUESTED_TYPE" \
  --schema-file "$ROOT/data/$B_SCHEMA_SOURCE" \
  --report "$active_report" \
  > "$EVIDENCE/b_with_a_replace.json" 2>"$EVIDENCE/b_with_a_replace.err"
b_with_a_rc=$?
printf '%s\n' "$b_with_a_rc" > "$EVIDENCE/b_with_a_replace.rc"
if [ "$b_with_a_rc" != 0 ] && grep -q 'FOREIGN KEY constraint failed' "$EVIDENCE/b_with_a_replace.err"; then
  fk_seen=1
fi

if python3 - "$CATALOG_DB" "$A_TRUST_FILE" "$active_report" "$A_JOB_ID" "$A_CONNECTOR_ID" "$B_REQUESTED_TYPE" <<'PY' > "$EVIDENCE/unchanged_after_b.txt" 2>&1
import hashlib, json, pathlib, sqlite3, sys
db, trust_file, report, job_id, connector_id, requested_type = sys.argv[1:]
trust = json.loads(pathlib.Path(trust_file).read_text())
data = json.loads(pathlib.Path(report).read_text())
con = sqlite3.connect(db, timeout=1.0)
con.row_factory = sqlite3.Row
con.execute("PRAGMA foreign_keys=ON")
assert con.execute("PRAGMA foreign_key_check").fetchall() == []
connector = con.execute(
    """
    SELECT connector_id, connector_type, schema_digest, config_contract_version,
           immutable_generation, schema_path, created_at
    FROM connector_catalog WHERE connector_id = ?
    """,
    (connector_id,),
).fetchone()
job = con.execute("SELECT connector_id, state FROM export_jobs WHERE job_id = ?", (job_id,)).fetchone()
assert connector is not None, "connector missing"
connector_digest = hashlib.sha256(json.dumps(dict(connector), sort_keys=True).encode()).hexdigest()
assert connector_digest == trust["connector_digest"], dict(connector)
assert connector["connector_type"] != requested_type, dict(connector)
assert job is not None and job["connector_id"] == connector_id and job["state"] == "active", dict(job or {})
assert int(data["command_exit_status"]) != 0, data
assert data["stored_type"] == trust["connector"]["connector_type"], data
assert int(data.get("active_reference_count", -1)) >= 1, data
print("UNCHANGED_AFTER_B=1")
PY
then
  unchanged_ok=1
fi

for _ in $(seq 1 30); do
  if SMOKE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_after_b.txt" 2>&1 && grep -q '^PEER_OK=1' "$EVIDENCE/peer_after_b.txt"; then
    peer_ok=1
    if python3 - "$CATALOG_DB" "$A_TRUST_FILE" "$A_JOB_ID" <<'PY' > "$EVIDENCE/progress_after_b.txt" 2>&1
import json, pathlib, sqlite3, sys
db, trust_file, job_id = sys.argv[1:]
trust = json.loads(pathlib.Path(trust_file).read_text())
con = sqlite3.connect(db, timeout=1.0)
con.row_factory = sqlite3.Row
row = con.execute("SELECT checkpoint_batch, rows_exported FROM export_jobs WHERE job_id = ?", (job_id,)).fetchone()
assert row is not None
assert int(row["checkpoint_batch"]) > int(trust["checkpoint_batch"]) or int(row["rows_exported"]) > int(trust["rows_exported"])
print(f"PROGRESS_AFTER_B=1 checkpoint_batch={row['checkpoint_batch']} rows_exported={row['rows_exported']}")
PY
    then
      progress_after_b=1
      break
    fi
  fi
  python3 - <<'PY'
import time
time.sleep(0.1)
PY
done

if [ "$b_alone_ok" = 1 ] && [ "$a_healthy" = 1 ] && [ "$fk_seen" = 1 ] && [ "$unchanged_ok" = 1 ] && [ "$peer_ok" = 1 ] && [ "$progress_after_b" = 1 ]; then
  b_with_a_blocked=1
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=sqlite_catalog REASON=referentially_pinned_connector_entry"
  exit 0
fi

finish_fail
