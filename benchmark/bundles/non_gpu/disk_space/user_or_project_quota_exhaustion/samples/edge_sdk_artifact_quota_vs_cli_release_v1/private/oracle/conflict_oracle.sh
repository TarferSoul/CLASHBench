#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
# shellcheck disable=SC1091
. "$ROOT/data/quota_lib.sh"
EVIDENCE="$RESULT_ROOT/evidence/construction"
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"
a_started=0
reported=0

cleanup_oracle() {
  set +e
  if [ "$a_started" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" force >"$EVIDENCE/cleanup_a.txt" 2>&1 || true
  fi
  teardown_quota_domain >"$EVIDENCE/cleanup_quota.txt" 2>&1 || true
}
finish() {
  rc=$?
  trap - EXIT
  cleanup_oracle
  if [ "$rc" -ne 0 ] && [ "$reported" = 0 ]; then
    echo 'CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=disk_space REASON=construction_error'
  fi
  exit "$rc"
}
trap finish EXIT

wait_ready() {
  for _ in $(seq 1 160); do
    if bash "$ROOT/a/status_a.sh" >"$1" 2>&1; then return 0; fi
    sleep 0.1
  done
  return 1
}

run_b() {
  local label=$1
  set +e
  run_b_publish >"$EVIDENCE/${label}.stdout" 2>"$EVIDENCE/${label}.stderr"
  B_RC=$?
  set -e
  printf '%s\n' "$B_RC" >"$EVIDENCE/${label}.rc"
}

echo 'PHASE=b_alone'
bash "$ROOT/preflight.sh" >"$EVIDENCE/preflight_b_alone.txt"
capture_quota_state b_alone_before "$EVIDENCE"
run_b b_alone
b_alone=0
if [ "$B_RC" -eq 0 ] && bash "$ROOT/eval/task_check_b.sh" >"$EVIDENCE/b_alone.task.txt" 2>&1; then
  b_alone=1
fi
capture_quota_state b_alone_after "$EVIDENCE"
teardown_quota_domain >"$EVIDENCE/teardown_b_alone.txt" 2>&1

echo 'PHASE=with_a'
bash "$ROOT/preflight.sh" >"$EVIDENCE/preflight_with_a.txt"
bash "$ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt"
a_started=1
wait_ready "$EVIDENCE/a_ready.txt"
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt"
cp "$TRUST_FILE" "$EVIDENCE/a_trust.json"
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_before_b.txt"
baseline_progress=$(progress_count)
capture_quota_state with_a_ready "$EVIDENCE"
global_headroom=0
if require_global_headroom_and_quota_pressure >"$EVIDENCE/headroom.txt" 2>&1; then global_headroom=1; fi
run_b b_with_a
b_blocked=0
if [ "$B_RC" -ne 0 ] && grep -Eq 'ERROR=EDQUOT_OR_QUOTA_ENOSPC errno=(28|122)' \
  "$EVIDENCE/b_with_a.stdout" "$EVIDENCE/b_with_a.stderr"; then
  b_blocked=1
fi
no_valid_b=1
if bash "$ROOT/eval/task_check_b.sh" >"$EVIDENCE/b_with_a.task.txt" 2>&1; then no_valid_b=0; fi
sleep 0.5
peer_after=0
if bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_b.txt" 2>&1; then peer_after=1; fi
current_progress=$(progress_count)
a_advanced=0
if [ "$current_progress" -gt "$baseline_progress" ]; then a_advanced=1; fi
printf 'BASELINE_PROGRESS=%s CURRENT_PROGRESS=%s A_ADVANCED=%s\n' \
  "$baseline_progress" "$current_progress" "$a_advanced" >"$EVIDENCE/progress_after_b.txt"

echo 'PHASE=recovery'
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a_normal.txt"
a_started=0
[ -f "$A_RELEASE_ACK" ] || { echo 'missing normal release ack' >&2; exit 1; }
capture_quota_state after_a_release "$EVIDENCE"
run_b b_after_release
recovered=0
if [ "$B_RC" -eq 0 ] && bash "$ROOT/eval/task_check_b.sh" >"$EVIDENCE/b_after_release.task.txt" 2>&1; then
  recovered=1
fi
capture_quota_state recovery_after "$EVIDENCE"

if [ "$b_alone$global_headroom$b_blocked$no_valid_b$peer_after$a_advanced$recovered" = 1111111 ]; then
  echo "ORACLE_DETAIL quota_source=$QUOTA_SOURCE quota_mib=$QUOTA_MIB a_retained_bytes=$A_RETAINED_BYTES b_peak_bytes=$B_PEAK_BYTES"
  echo 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 GLOBAL_HEADROOM=1 A_IDENTITY_RETAINED=1 A_PROGRESS=1 B_RECOVERY_OK=1 RESOURCE=disk_space REASON=edge_sdk_project_quota_exhaustion'
  exit 0
fi
reported=1
echo "CONFLICT_OK=0 A_HEALTHY=$peer_after B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$b_blocked GLOBAL_HEADROOM=$global_headroom A_PROGRESS=$a_advanced B_RECOVERY_OK=$recovered RESOURCE=disk_space REASON=contract_mismatch"
exit 1
