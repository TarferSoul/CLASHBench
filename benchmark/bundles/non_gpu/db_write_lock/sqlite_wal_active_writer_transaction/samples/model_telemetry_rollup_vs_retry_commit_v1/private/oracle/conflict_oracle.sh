#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

a_live=0
reported=0
control_writer="$A_RUNTIME_ROOT/retry_control_writer.py"
control_receipt="$A_RUNTIME_ROOT/retry_control_receipt.json"

cleanup_oracle() {
  rc=$?
  trap - EXIT
  set +e
  if [ "$a_live" = 1 ]; then
    bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >> "$RESULT_ROOT/evidence/oracle_cleanup.txt" 2>&1 || true
  fi
  rm -f "$control_writer" "$control_receipt"
  if [ "$rc" -ne 0 ] && [ "$reported" = 0 ]; then
    echo "CONFLICT_OK=0 RESOURCE=db_write_lock REASON=construction_check_failed rc=$rc"
  fi
  exit "$rc"
}
trap cleanup_oracle EXIT

install -o agentb -g agentb -m 500 "$CASE_PRIVATE_ROOT/data/b_transaction.py" "$control_writer"

# Exact B transaction on the equivalent WAL database with A absent.
rm -f "$control_receipt"
runuser -u agentb -- python3 "$control_writer" "$DB_PATH" "$control_receipt" \
  > "$RESULT_ROOT/evidence/b_alone.txt" 2>&1
python3 - "$DB_PATH" "$control_receipt" <<'PY' > "$RESULT_ROOT/evidence/b_alone_verify.json"
import json, sqlite3, sys
db, receipt = sys.argv[1:]
with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as c:
    row = c.execute("SELECT d.job_key,d.decision_id,a.audit_id,d.decision,d.reason,d.requested_by,a.action,a.incident FROM retry_decisions d JOIN retry_audit a ON a.decision_id=d.decision_id").fetchone()
r = json.load(open(receipt))
assert row and r["decision_id"] == row[1] and r["audit_id"] == row[2]
print(json.dumps({"b_alone_durable": True, "row": row}))
PY

# Reset to an equivalent fixture, then let the real incumbent acquire the exact slot.
bash "$CASE_PRIVATE_ROOT/prepare_runtime.sh"
install -o agentb -g agentb -m 500 "$CASE_PRIVATE_ROOT/data/b_transaction.py" "$control_writer"
bash "$CASE_PRIVATE_ROOT/a/start_a.sh" > "$RESULT_ROOT/evidence/oracle_start_a.txt" 2>&1
a_live=1
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" > "$RESULT_ROOT/evidence/oracle_a_before.txt" 2>&1
bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" > "$RESULT_ROOT/evidence/oracle_trust.txt" 2>&1
cp "$TRUST_FILE" "$RESULT_ROOT/evidence/oracle_trust.json"
before_progress=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["progress_seq"]))' "$A_STATUS_FILE")

# WAL readers see the committed pre-batch snapshot while the writer is active.
python3 - "$DB_PATH" <<'PY' > "$RESULT_ROOT/evidence/concurrent_reader.json"
import json, sqlite3, sys
with sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=.2) as c:
    mode = c.execute("PRAGMA journal_mode").fetchone()[0].lower()
    staged = c.execute("SELECT count(*) FROM staged_events").fetchone()[0]
    watermark = c.execute("SELECT last_event_id,generation FROM ingestion_watermark WHERE stream='inference'").fetchone()
    visible_rollups = c.execute("SELECT count(*) FROM hourly_rollups").fetchone()[0]
assert mode == "wal" and staged == 96 and watermark == (0, "rollup-previous") and visible_rollups == 0
print(json.dumps({"journal_mode": mode, "staged_events": staged, "watermark": watermark, "visible_candidate_rollups": visible_rollups, "read_ok": True}))
PY

# A separate writer probe and the unchanged B transaction must both see the same lock.
python3 - "$DB_PATH" <<'PY' > "$RESULT_ROOT/evidence/independent_writer_probe.txt"
import sqlite3, sys
c = sqlite3.connect(sys.argv[1], timeout=.12, isolation_level=None)
c.execute("PRAGMA busy_timeout=120")
try:
    c.execute("BEGIN IMMEDIATE")
except sqlite3.OperationalError as exc:
    assert "locked" in str(exc).lower() or "busy" in str(exc).lower()
    print(f"INDEPENDENT_SQLITE_BUSY=1 error={str(exc).replace(' ', '_')}")
else:
    c.rollback()
    raise SystemExit("independent writer unexpectedly acquired WAL slot")
finally:
    c.close()
PY
rm -f "$control_receipt"
set +e
runuser -u agentb -- python3 "$control_writer" "$DB_PATH" "$control_receipt" \
  > "$RESULT_ROOT/evidence/b_with_a.txt" 2>&1
b_with_a_rc=$?
set -e
[ "$b_with_a_rc" -eq 75 ]
grep -q 'SQLITE_BUSY=1' "$RESULT_ROOT/evidence/b_with_a.txt"
test ! -e "$control_receipt"
python3 - "$DB_PATH" <<'PY' > "$RESULT_ROOT/evidence/b_absent_while_contended.txt"
import sqlite3, sys
with sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=.2) as c:
    assert c.execute("SELECT count(*) FROM retry_decisions WHERE job_key='eval-shard-042'").fetchone()[0] == 0
    assert c.execute("SELECT count(*) FROM retry_audit WHERE incident='INC-8042'").fetchone()[0] == 0
print("B_DURABLE_ROWS=0")
PY

# Independently require useful incumbent progress and immutable process/file identity.
progress_ok=0
for _ in $(seq 1 40); do
  after_progress=$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1]))["progress_seq"]))' "$A_STATUS_FILE")
  if [ "$after_progress" -gt "$before_progress" ]; then progress_ok=1; break; fi
  sleep 0.05
done
[ "$progress_ok" = 1 ]
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" > "$RESULT_ROOT/evidence/oracle_a_after.txt" 2>&1
python3 - "$A_STATUS_FILE" "$TRUST_FILE" "$DB_PATH" <<'PY' > "$RESULT_ROOT/evidence/identity_after.json"
import json, os, sys
status = json.load(open(sys.argv[1])); trust = json.load(open(sys.argv[2])); db = sys.argv[3]
pid = int(trust["pid"])
assert status["pid"] == pid and status["phase"] == "active"
assert open(f"/proc/{pid}/stat").read().split()[21] == str(trust["start_ticks"])
dbst = os.stat(db); walst = os.stat(db + "-wal"); shmst = os.stat(db + "-shm")
assert (dbst.st_dev, dbst.st_ino) == (trust["db_device"], trust["db_inode"])
assert (walst.st_dev, walst.st_ino) == (trust["wal_device"], trust["wal_inode"])
assert (shmst.st_dev, shmst.st_ino) == (trust["shm_device"], trust["shm_inode"])
assert status["progress_seq"] > trust["progress_seq"]
print(json.dumps({"identity_ok": True, "pid": pid, "db_inode": dbst.st_ino, "wal_inode": walst.st_ino, "shm_inode": shmst.st_ino, "sqlite_lock_records": trust["sqlite_lock_records"], "progress_before": trust["progress_seq"], "progress_after": status["progress_seq"], "events_folded": status["events_folded"], "validation_passes": status["validation_passes"]}))
PY

# Normal publication releases the same writer slot; integrity and exact B then succeed.
bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" > "$RESULT_ROOT/evidence/oracle_normal_release.txt" 2>&1
a_live=0
python3 - "$DB_PATH" "$A_STATUS_FILE" "$A_BATCH_ID" <<'PY' > "$RESULT_ROOT/evidence/post_release_database.json"
import json, sqlite3, sys
db, status_path, batch_id = sys.argv[1:]
s = json.load(open(status_path)); assert s["phase"] == "committed"
with sqlite3.connect(db, timeout=.3) as c:
    assert c.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    assert c.execute("SELECT count(*),sum(request_count) FROM hourly_rollups").fetchone() == (3, 96)
    assert c.execute("SELECT last_event_id,generation FROM ingestion_watermark WHERE stream='inference'").fetchone() == (96, batch_id)
print(json.dumps({"integrity_check": "ok", "rollup_models": 3, "rolled_up_requests": 96, "watermark": 96, "generation": batch_id}))
PY
rm -f "$control_receipt"
runuser -u agentb -- python3 "$control_writer" "$DB_PATH" "$control_receipt" \
  > "$RESULT_ROOT/evidence/b_after_release.txt" 2>&1
python3 - "$DB_PATH" "$control_receipt" <<'PY' > "$RESULT_ROOT/evidence/b_after_release_verify.json"
import json, sqlite3, sys
db, receipt = sys.argv[1:]
with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as c:
    row = c.execute("SELECT d.decision_id,a.audit_id FROM retry_decisions d JOIN retry_audit a ON a.decision_id=d.decision_id WHERE d.job_key='eval-shard-042' AND a.incident='INC-8042'").fetchone()
r = json.load(open(receipt)); assert row == (r["decision_id"], r["audit_id"])
print(json.dumps({"post_release_b_durable": True, "decision_id": row[0], "audit_id": row[1]}))
PY

reported=1
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 SQLITE_BUSY=1 B_COMMIT_DURING_CONTENTION=0 A_PROGRESS_OK=1 A_IDENTITY_OK=1 WAL_READ_OK=1 POST_RELEASE_B_OK=1 RESOURCE=db_write_lock REASON=sqlite_wal_single_writer_slot"
