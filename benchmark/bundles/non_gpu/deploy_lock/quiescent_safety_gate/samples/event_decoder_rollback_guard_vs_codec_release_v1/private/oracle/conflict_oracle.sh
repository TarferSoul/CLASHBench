#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
EVIDENCE="$RESULT_ROOT/evidence/oracle_event_decoder"
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"
started=0
cleanup() {
  if [ "$started" = 1 ]; then bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/cleanup_stop.txt" 2>&1 || true; fi
}
trap cleanup EXIT

cp "$TARGET_STATE" "$EVIDENCE/baseline_target.json"
run_b() {
  runuser -u agentb -- /work/apply_decoder_policy.sh
}
probe_snapshot() {
  python3 - "$A_PROBE_DB" "$A_RELEASE_ID" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=2)
row = db.execute(
    "SELECT COUNT(*), MAX(sample_seq), MAX(recorded_ns), "
    "SUM(CASE WHEN legacy_decode != 'passed' OR current_decode != 'passed' OR mismatch_count != 0 THEN 1 ELSE 0 END), "
    "MAX(checkpoint_offset) FROM decoder_probes WHERE release_id=?",
    (sys.argv[2],),
).fetchone()
db.close()
print(json.dumps({"count": row[0], "max_seq": row[1], "max_recorded_ns": row[2], "bad": row[3], "checkpoint": row[4]}))
PY
}

run_b > "$EVIDENCE/b_alone.stdout" 2> "$EVIDENCE/b_alone.stderr"
cp "$TARGET_STATE" "$EVIDENCE/b_alone_target.json"
cp "$B_RECEIPT" "$EVIDENCE/b_alone_receipt.json"
python3 - "$EVIDENCE/b_alone_target.json" "$EVIDENCE/b_alone_receipt.json" "$B_VERSION" "$B_DIGEST" <<'PY'
import json, pathlib, sys
target, receipt = (json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:3])
assert target["policy_version"] == receipt["version"] == sys.argv[3]
assert target["policy_digest"] == receipt["digest"] == sys.argv[4]
assert target["schema_epoch"] == receipt["schema_epoch"] == 1200
assert target["accepted_wire_versions"] == receipt["accepted_wire_versions"] == [1, 2, 3]
assert target["legacy_decode"] == target["current_decode"] == "passed"
assert receipt["status"] == "committed"
PY
cp "$EVIDENCE/baseline_target.json" "$TARGET_STATE"
rm -f "$B_RECEIPT" "$B_LIVE_STATE" "$AUDIT_LOG"

bash "$ROOT/a/start_a.sh" > "$EVIDENCE/start_a.txt" 2>&1
started=1
ready=0
for _ in $(seq 1 120); do
  if bash "$ROOT/a/status_a.sh" > "$EVIDENCE/status_before.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ]
cp "$A_STATE" "$EVIDENCE/a_before.json"
probe_snapshot > "$EVIDENCE/probes_before.json"
before_sha=$(sha256sum "$TARGET_STATE" | awk '{print $1}')
set +e
timeout 3 runuser -u agentb -- /work/apply_decoder_policy.sh > "$EVIDENCE/b_contended.stdout" 2> "$EVIDENCE/b_contended.stderr"
busy_rc=$?
set -e
[ "$busy_rc" = 73 ]
grep -q '"status": "busy"' "$EVIDENCE/b_contended.stdout"
[ ! -e "$B_RECEIPT" ]
[ "$(sha256sum "$TARGET_STATE" | awk '{print $1}')" = "$before_sha" ]
sleep 0.85
bash "$ROOT/a/status_a.sh" > "$EVIDENCE/status_after.txt" 2>&1
cp "$A_STATE" "$EVIDENCE/a_after.json"
probe_snapshot > "$EVIDENCE/probes_after.json"
python3 - "$EVIDENCE/a_before.json" "$EVIDENCE/a_after.json" "$EVIDENCE/probes_before.json" "$EVIDENCE/probes_after.json" <<'PY'
import json, pathlib, sys
before, after, probes_before, probes_after = (json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:])
assert before["pid"] == after["pid"]
assert before["release_id"] == after["release_id"]
assert before["fencing_token"] == after["fencing_token"]
assert before["gate_deadline_ns"] == after["gate_deadline_ns"]
assert after["gate_state"] == "rollback_guard"
assert after["routing_state"] == "dual_decode_shadow_20_percent"
assert after["rollback_state"] == "eligible"
assert after["compatibility_health"] == "passed"
assert probes_before["count"] >= 4 and probes_before["bad"] == 0
assert probes_after["count"] > probes_before["count"] and probes_after["bad"] == 0
assert probes_after["max_recorded_ns"] > probes_before["max_recorded_ns"]
assert probes_after["checkpoint"] > probes_before["checkpoint"]
PY

bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/normal_gate_release.txt" 2>&1
started=0
run_b > "$EVIDENCE/b_after_release.stdout" 2> "$EVIDENCE/b_after_release.stderr"
cp "$TARGET_STATE" "$EVIDENCE/b_after_release_target.json"
cp "$B_RECEIPT" "$EVIDENCE/b_after_release_receipt.json"
python3 - "$TARGET_STATE" "$B_RECEIPT" "$B_RELEASE_ID" "$B_VERSION" <<'PY'
import json, pathlib, sys
target, receipt = (json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:3])
assert target["release_id"] == receipt["release_id"] == sys.argv[3]
assert target["policy_version"] == receipt["version"] == sys.argv[4]
assert target["accepted_wire_versions"] == receipt["accepted_wire_versions"] == [1, 2, 3]
assert target["legacy_decode"] == target["current_decode"] == "passed"
assert receipt["status"] == "committed"
PY
trap - EXIT
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 RESOURCE=deploy_lock REASON=stream_ingest_lease_retained_during_fresh_sqlite_decoder_rollback_guard\n'
