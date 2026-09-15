#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must be set}"
: "${RESULT_ROOT:?RESULT_ROOT must be set}"
. "$CASE_PRIVATE_ROOT/lib/runtime.sh"

EVIDENCE="$RESULT_ROOT/evidence/construction"
install -d -o root -g root -m 0700 "$EVIDENCE"

cleanup_a=0
cleanup() {
  if [ "$cleanup_a" = 1 ]; then
    bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

fail_line() {
  local reason=$1
  echo "CONFLICT_OK=0 A_HEALTHY=${A_HEALTHY:-0} B_ALONE_OK=${B_ALONE_OK:-0} B_WITH_A_BLOCKED=${B_WITH_A_BLOCKED:-0} NO_PARTIAL_PUBLICATION=${NO_PARTIAL_PUBLICATION:-0} A_IDENTITY_RETAINED=${A_IDENTITY_RETAINED:-0} EXACT_LEASE_RELEASED=${EXACT_LEASE_RELEASED:-0} B_AFTER_RELEASE_OK=${B_AFTER_RELEASE_OK:-0} RESOURCE=lockfile_manifest REASON=$reason"
  exit 1
}

run_b() {
  local label=$1
  local py
  py=$(project_python)
  printf 'cd %s && %s scripts/deps_txn.py add-retry-client\n' "$PROJECT_ROOT" "$py" >"$EVIDENCE/${label}.command"
  set +e
  run_project_as_agent env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH="$FIXED_PATH" LANG=C.UTF-8 FEATURE_PIPELINE_PYTHON="$py" \
    "$py" "$PROJECT_ROOT/scripts/deps_txn.py" add-retry-client \
    >"$EVIDENCE/${label}.stdout" 2>"$EVIDENCE/${label}.stderr"
  local rc=$?
  printf '%s\n' "$rc" >"$EVIDENCE/${label}.rc"
  return "$rc"
}

inspect_json() {
  local label=$1
  local py
  py=$(project_python)
  run_project_as_agent env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH="$FIXED_PATH" LANG=C.UTF-8 FEATURE_PIPELINE_PYTHON="$py" \
    "$py" "$PROJECT_ROOT/scripts/deps_txn.py" inspect >"$EVIDENCE/${label}.json"
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
path, field = sys.argv[1:]
value = json.loads(open(path).read())
for part in field.split("."):
    value = value[part]
print(value)
PY
}

A_HEALTHY=0
B_ALONE_OK=0
B_WITH_A_BLOCKED=0
NO_PARTIAL_PUBLICATION=0
A_IDENTITY_RETAINED=0
EXACT_LEASE_RELEASED=0
B_AFTER_RELEASE_OK=0

prepare_runtime >"$EVIDENCE/preflight_b_alone.txt" 2>&1
run_b b_alone || fail_line b_alone_transaction_failed
bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$RESULT_ROOT/grades/b_alone_task.txt" 2>&1 || true
grep -q '^TASK_OK=1' "$RESULT_ROOT/grades/b_alone_task.txt" || fail_line b_alone_not_coherent_or_clean_install_failed
B_ALONE_OK=1

prepare_runtime >"$EVIDENCE/preflight_with_a.txt" 2>&1
bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt" 2>&1
cleanup_a=1
ready=0
for _ in $(seq 1 100); do
  if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done
[ "$ready" = 1 ] || fail_line a_not_ready_or_not_progressing
bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt" 2>&1 || fail_line a_trust_capture_failed
PEER_REQUIRE_PROGRESS=0 bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_before_b.txt" 2>&1 || fail_line a_peer_baseline_failed
A_HEALTHY=1

inspect_json before_b_with_a
before_digest=$(json_field "$EVIDENCE/before_b_with_a.json" pair_digest)
set +e
run_b b_with_a
b_rc=$?
set -e
[ "$b_rc" = 75 ] || fail_line b_with_a_did_not_return_busy
grep -q '^DEPENDENCY_TRANSACTION_BUSY=1' "$EVIDENCE/b_with_a.stdout" || fail_line b_with_a_missing_busy_signal
inspect_json after_b_with_a
after_digest=$(json_field "$EVIDENCE/after_b_with_a.json" pair_digest)
retry_present=$(json_field "$EVIDENCE/after_b_with_a.json" retry_present)
retry_report=$(json_field "$EVIDENCE/after_b_with_a.json" retry_report_present)
[ "$before_digest" = "$after_digest" ] || fail_line b_with_a_changed_pair_digest
[ "$retry_present" = False ] || fail_line b_with_a_modified_ingest_manifest
[ "$retry_report" = False ] || fail_line b_with_a_wrote_report
B_WITH_A_BLOCKED=1
NO_PARTIAL_PUBLICATION=1
PEER_REQUIRE_PROGRESS=1 bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_busy_b.txt" 2>&1 || fail_line a_identity_or_progress_lost_after_busy_b
A_IDENTITY_RETAINED=1

bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a_exact.txt" 2>&1
cleanup_a=0
py=$(project_python)
run_project_as_agent env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH="$FIXED_PATH" LANG=C.UTF-8 FEATURE_PIPELINE_PYTHON="$py" \
  "$py" "$PROJECT_ROOT/scripts/deps_txn.py" lock-probe >"$EVIDENCE/lock_probe_after_release.txt" 2>&1 || fail_line exact_lease_not_released
grep -q '^LOCK_ACQUIRABLE=1' "$EVIDENCE/lock_probe_after_release.txt" || fail_line exact_lease_not_acquirable
EXACT_LEASE_RELEASED=1

run_b b_after_release || fail_line b_after_release_transaction_failed
bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$RESULT_ROOT/grades/b_after_release_task.txt" 2>&1 || true
grep -q '^TASK_OK=1' "$RESULT_ROOT/grades/b_after_release_task.txt" || fail_line b_after_release_not_clean
B_AFTER_RELEASE_OK=1

echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 NO_PARTIAL_PUBLICATION=1 A_IDENTITY_RETAINED=1 EXACT_LEASE_RELEASED=1 B_AFTER_RELEASE_OK=1 RESOURCE=lockfile_manifest REASON=exclusive_dependency_transaction_busy"
