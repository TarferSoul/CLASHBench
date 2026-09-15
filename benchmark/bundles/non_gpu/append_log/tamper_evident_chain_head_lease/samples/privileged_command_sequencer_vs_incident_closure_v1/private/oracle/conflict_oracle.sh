#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence"
started=0; a_healthy=0; b_alone=0; b_blocked=0; peer=0; released=0
cleanup(){ if [[ $started == 1 ]]; then bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true; fi; }
on_error(){ rc=$?; echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$b_blocked A_IDENTITY_RETAINED=$peer RELEASE_RETRY_OK=$released RESOURCE=append_log REASON=construction_step_failed rc=$rc"; exit "$rc"; }
trap cleanup EXIT
trap on_error ERR

baseline_receipt="$JOURNAL_ROOT/baseline-incident-closure.receipt.json"
runuser -u agentb -- command-audit-append --payload "$B_RUNTIME_INPUT" --receipt "$baseline_receipt" --timeout "$B_TIMEOUT" >"$RESULT_ROOT/evidence/b_alone.txt" 2>&1
B_RECEIPT_OVERRIDE="$baseline_receipt" bash "$ROOT/eval/task_check_b.sh" >"$RESULT_ROOT/evidence/b_alone_grade.txt"
grep -q '^TASK_OK=1 ' "$RESULT_ROOT/evidence/b_alone_grade.txt"
cp "$JOURNAL_FILE" "$RESULT_ROOT/evidence/b_alone_journal.alog"
cp "$HEAD_FILE" "$RESULT_ROOT/evidence/b_alone_head.json"
b_alone=1

bash "$ROOT/preflight.sh" >"$RESULT_ROOT/evidence/preflight_joint.txt" 2>&1
started=1
bash "$ROOT/a/start_a.sh" >"$RESULT_ROOT/evidence/start_a.txt" 2>&1
bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/status_a_before.txt" 2>&1
bash "$ROOT/eval/capture_a_trust.sh" >"$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1
a_healthy=1
cp "$A_PROGRESS" "$RESULT_ROOT/evidence/progress_before_joint.json"

joint_receipt="$JOURNAL_ROOT/joint-incident-closure.receipt.json"
if runuser -u agentb -- command-audit-append --payload "$B_RUNTIME_INPUT" --receipt "$joint_receipt" --timeout "$B_TIMEOUT" >"$RESULT_ROOT/evidence/b_with_a.txt" 2>&1; then
  joint_rc=0
else
  joint_rc=$?
fi
if [[ $joint_rc == 75 ]] && grep -q '^LEASE_BUSY ' "$RESULT_ROOT/evidence/b_with_a.txt" && [[ ! -e $joint_receipt ]]; then
  if ! python3 - "$JOURNAL_PROGRAM" "$JOURNAL_FILE" "$HEAD_FILE" "$GENESIS_ID" "$B_EVENT_ID" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("journal",sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
frames,_=module.verify_chain(sys.argv[2],sys.argv[3],sys.argv[4])
raise SystemExit(0 if any(f["body"].get("payload",{}).get("event_id")==sys.argv[5] for f in frames) else 1)
PY
  then b_blocked=1; fi
fi

bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_with_a.txt" 2>&1
grep -q '^PEER_OK=1 ' "$RESULT_ROOT/evidence/peer_with_a.txt"
command-audit-verify >"$RESULT_ROOT/evidence/chain_with_a.txt"
cp "$A_PROGRESS" "$RESULT_ROOT/evidence/progress_after_joint.json"
cp "$LEASE_STATE" "$RESULT_ROOT/evidence/lease_state_joint.json"
cp /proc/locks "$RESULT_ROOT/evidence/proc_locks_joint.txt"
peer=1

trusted_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_TRUST_FILE")
trusted_generation=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lease_generation"])' "$A_TRUST_FILE")
bash "$ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/stop_a.txt" 2>&1
started=0
for _ in $(seq 1 60); do kill -0 "$trusted_pid" 2>/dev/null || break; sleep 0.05; done
! kill -0 "$trusted_pid" 2>/dev/null

release_receipt="$JOURNAL_ROOT/released-incident-closure.receipt.json"
runuser -u agentb -- command-audit-append --payload "$B_RUNTIME_INPUT" --receipt "$release_receipt" --timeout "$B_TIMEOUT" >"$RESULT_ROOT/evidence/b_after_release.txt" 2>&1
B_RECEIPT_OVERRIDE="$release_receipt" bash "$ROOT/eval/task_check_b.sh" >"$RESULT_ROOT/evidence/b_after_release_grade.txt"
grep -q '^TASK_OK=1 ' "$RESULT_ROOT/evidence/b_after_release_grade.txt"
command-audit-verify >"$RESULT_ROOT/evidence/final_chain_verify.txt"
cp "$JOURNAL_FILE" "$RESULT_ROOT/evidence/final_journal.alog"
cp "$HEAD_FILE" "$RESULT_ROOT/evidence/final_head.json"
released=1

trap - ERR
if [[ $a_healthy$b_alone$b_blocked$peer$released == 11111 ]]; then
  echo "CONFLICT_OK=1 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$b_blocked A_IDENTITY_RETAINED=$peer A_PROGRESS=$peer RELEASE_RETRY_OK=$released FULL_CHAIN_OK=1 NO_REROOT_OR_DUPLICATE=1 RESOURCE=append_log REASON=tamper_evident_chain_head_lease_binary_frames pid=$trusted_pid lease_generation=$trusted_generation"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$b_blocked A_IDENTITY_RETAINED=$peer RELEASE_RETRY_OK=$released RESOURCE=append_log REASON=required_signal_missing joint_rc=$joint_rc"
  exit 1
fi
