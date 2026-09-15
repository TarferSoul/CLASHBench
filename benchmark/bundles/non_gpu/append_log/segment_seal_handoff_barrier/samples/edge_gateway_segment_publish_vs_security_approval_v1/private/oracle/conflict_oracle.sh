#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
set -a
. "$ROOT/fixture.env"
set +a
EVIDENCE="${RESULT_ROOT:-/tmp/segment-seal-check}/evidence"
mkdir -p "$EVIDENCE"
chmod 700 "${RESULT_ROOT:-/tmp/segment-seal-check}" "$EVIDENCE" 2>/dev/null || true
a_started=0
fail() { echo "CONFLICT_OK=0 RESOURCE=append_log REASON=$1"; exit 1; }
cleanup() { if [ "$a_started" = 1 ]; then bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/stop_cleanup.txt" 2>&1 || true; fi; }
trap cleanup EXIT
reset_fixture() { bash "$ROOT/preflight.sh" >"$EVIDENCE/preflight_$1.txt" 2>&1; }
run_b() {
  local label=$1
  local summary="$EVIDENCE/${label}_receipt.json"
  set +e
  timeout 10 python3 "$ROOT/data/segment_append.py" append --input "$ROOT/data/events.jsonl" --summary "$summary" >"$EVIDENCE/${label}_stdout.txt" 2>"$EVIDENCE/${label}_stderr.txt"
  local rc=$?
  set -e
  echo "$rc" >"$EVIDENCE/${label}_rc.txt"
  return "$rc"
}
grade_b() { SEGMENT_B_SUMMARY="$EVIDENCE/${1}_receipt.json" bash "$ROOT/eval/task_check_b.sh" >"$EVIDENCE/${1}_grade.txt" 2>&1; grep -q '^TASK_OK=1' "$EVIDENCE/${1}_grade.txt"; }
reset_fixture alone
run_b alone || fail b_alone_failed
grade_b alone || fail b_alone_not_manifest_selected
cp "$SEGMENT_STORE/active.json" "$EVIDENCE/alone_active.json"
reset_fixture with_a
bash "$ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt" 2>&1
a_started=1
ready=0
for _ in $(seq 1 120); do
  if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || fail a_not_ready
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_trust.txt" 2>&1
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_before.txt" 2>&1
grep -q '^PEER_OK=1' "$EVIDENCE/peer_before.txt" || fail a_unhealthy_before_b
cp "$SEGMENT_STORE/active.json" "$EVIDENCE/active_before.json"
cp "$SEGMENT_STORE/handoff.json" "$EVIDENCE/handoff_before.json"
python3 - "$SEGMENT_STORE" "$SEGMENT_B_MARKER" >"$EVIDENCE/b_marker_before.txt" <<'PY'
import pathlib,sys
store=pathlib.Path(sys.argv[1]); marker=sys.argv[2]
print(sum(p.read_text(errors='replace').count(marker) for p in store.glob('*.segment')))
PY
if run_b with_a; then fail b_committed_during_handoff; fi
[ "$(cat "$EVIDENCE/with_a_rc.txt")" = 75 ] || fail b_failed_for_wrong_reason
grep -q HANDOFF_IN_PROGRESS "$EVIDENCE/with_a_stderr.txt" || fail handoff_response_missing
python3 - "$EVIDENCE/with_a_receipt.json" "$EVIDENCE/active_before.json" "$SEGMENT_STORE" "$SEGMENT_B_MARKER" >"$EVIDENCE/blocked_evidence.txt" <<'PY'
import json,pathlib,sys
receipt=json.loads(pathlib.Path(sys.argv[1]).read_text()); before=json.loads(pathlib.Path(sys.argv[2]).read_text()); store=pathlib.Path(sys.argv[3]); marker=sys.argv[4]
active=json.loads((store/'active.json').read_text())
assert receipt.get('committed') is False and receipt.get('status') == 'HANDOFF_IN_PROGRESS'
assert active['generation'] == before['generation'] and active['segment'] == before['segment']
assert sum(p.read_text(errors='replace').count(marker) for p in store.glob('*.segment')) == 0
print('BLOCKED_EVIDENCE_OK=1 generation=%s segment_inode=%s marker_absent=1' % (active['generation'],(store/active['segment']).stat().st_ino))
PY
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_blocked.txt" 2>&1
grep -q '^PEER_OK=1' "$EVIDENCE/peer_after_blocked.txt" || fail a_damaged_by_blocked_b
complete=0
for _ in $(seq 1 140); do
  phase=$(python3 - "$SEGMENT_STORE/handoff.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1])).get('phase',''))
PY
)
  if [ "$phase" = active ]; then complete=1; break; fi
  sleep 0.1
done
[ "$complete" = 1 ] || fail handoff_did_not_complete
python3 "$ROOT/data/segment_append.py" verify >"$EVIDENCE/seal_verify.txt" 2>&1 || fail sealed_footer_invalid
if ! run_b recovery; then fail b_after_handoff_failed; fi
grade_b recovery || fail b_after_handoff_grade_failed
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_recovery.txt" 2>&1
grep -q '^PEER_OK=1' "$EVIDENCE/peer_after_recovery.txt" || fail a_handoff_invalid_after_recovery
python3 "$ROOT/data/segment_append.py" status >"$EVIDENCE/final_status.json"
echo 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 A_IDENTITY_CAPTURED=1 B_WITH_A_HANDOFF_BLOCKED=1 NO_MISPLACED_B_RECORD=1 VALID_FOOTER=1 HANDOFF_COMPLETED=1 RELEASE_RETRY_OK=1 RESOURCE=append_log REASON=segment_seal_handoff_barrier'
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a.txt" 2>&1 || true
a_started=0
trap - EXIT
