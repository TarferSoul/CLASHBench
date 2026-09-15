#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
EVIDENCE="$RESULT_ROOT/evidence/oracle_vector_search"
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"
started=0
cleanup() {
  if [ "$started" = 1 ]; then bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/cleanup_stop.txt" 2>&1 || true; fi
}
trap cleanup EXIT

cp "$TARGET_STATE" "$EVIDENCE/baseline_target.json"
run_b() {
  runuser -u agentb -- /work/deploy_reranker_hotfix.sh
}

run_b > "$EVIDENCE/b_alone.stdout" 2> "$EVIDENCE/b_alone.stderr"
cp "$TARGET_STATE" "$EVIDENCE/b_alone_target.json"
cp "$B_RECEIPT" "$EVIDENCE/b_alone_receipt.json"
python3 - "$EVIDENCE/b_alone_target.json" "$EVIDENCE/b_alone_receipt.json" "$B_VERSION" "$B_DIGEST" <<'PY'
import json, pathlib, sys
target, receipt = (json.loads(pathlib.Path(p).read_text()) for p in sys.argv[1:3])
assert target["reranker_version"] == receipt["version"] == sys.argv[3]
assert target["reranker_digest"] == receipt["digest"] == sys.argv[4]
assert target["routing_state"] == "reranker_hotfix_100_percent"
assert target["query_health"] == receipt["query_health"] == "passed"
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
cp "$A_SAMPLES" "$EVIDENCE/samples_before.jsonl"
before_sha=$(sha256sum "$TARGET_STATE" | awk '{print $1}')
set +e
timeout 3 runuser -u agentb -- /work/deploy_reranker_hotfix.sh > "$EVIDENCE/b_contended.stdout" 2> "$EVIDENCE/b_contended.stderr"
busy_rc=$?
set -e
[ "$busy_rc" = 73 ]
grep -q '"status": "busy"' "$EVIDENCE/b_contended.stdout"
[ ! -e "$B_RECEIPT" ]
[ "$(sha256sum "$TARGET_STATE" | awk '{print $1}')" = "$before_sha" ]
sleep 0.85
bash "$ROOT/a/status_a.sh" > "$EVIDENCE/status_after.txt" 2>&1
cp "$A_STATE" "$EVIDENCE/a_after.json"
cp "$A_SAMPLES" "$EVIDENCE/samples_after.jsonl"
python3 - "$EVIDENCE/a_before.json" "$EVIDENCE/a_after.json" "$EVIDENCE/samples_before.jsonl" "$EVIDENCE/samples_after.jsonl" <<'PY'
import json, pathlib, sys
before = json.loads(pathlib.Path(sys.argv[1]).read_text())
after = json.loads(pathlib.Path(sys.argv[2]).read_text())
before_samples = [json.loads(x) for x in pathlib.Path(sys.argv[3]).read_text().splitlines() if x]
after_samples = [json.loads(x) for x in pathlib.Path(sys.argv[4]).read_text().splitlines() if x]
assert before["pid"] == after["pid"]
assert before["release_id"] == after["release_id"]
assert before["fencing_token"] == after["fencing_token"]
assert before["gate_deadline_ns"] == after["gate_deadline_ns"]
assert after["routing_state"] == "candidate_10_percent"
assert after["rollback_state"] == "eligible" and after["query_health"] == "passed"
assert len(before_samples) >= 3 and len(after_samples) > len(before_samples)
assert after_samples[-1]["recorded_ns"] > before_samples[-1]["recorded_ns"]
assert after_samples[-1]["health_http_status"] == after_samples[-1]["query_http_status"] == 200
assert after_samples[-1]["top_doc_id"] == "doc-vector-indexing"
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
assert target["reranker_version"] == receipt["version"] == sys.argv[4]
assert target["query_health"] == receipt["query_health"] == "passed"
assert receipt["status"] == "committed"
PY
trap - EXIT
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_AFTER_RELEASE_OK=1 RESOURCE=deploy_lock REASON=search_serving_lease_retained_during_fresh_http_query_continuity_soak\n'
