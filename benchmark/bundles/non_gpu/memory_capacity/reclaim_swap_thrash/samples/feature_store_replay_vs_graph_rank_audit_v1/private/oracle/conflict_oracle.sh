#!/usr/bin/env bash
set -Eeuo pipefail
[ "$(id -u)" = 0 ] || { echo "CONFLICT_OK=0 REASON=root_required"; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
: "${RESULT_ROOT:?RESULT_ROOT is required}"
EVIDENCE="$RESULT_ROOT/evidence/construction"
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"
FAIL_REASON=unexpected_failure
REPORTED=0
A_ACTIVE=0

cleanup() {
  set +e
  if [ "$A_ACTIVE" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" >>"$EVIDENCE/cleanup_stop_a.txt" 2>&1
    A_ACTIVE=0
  fi
}

finish() {
  rc=$?
  trap - EXIT
  cleanup
  if [ "$rc" -ne 0 ] && [ "$REPORTED" = 0 ]; then
    echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=memory_capacity REASON=$FAIL_REASON"
  fi
  exit "$rc"
}
trap finish EXIT

fail() {
  FAIL_REASON=$1
  return 1
}

cg_rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
CG="/sys/fs/cgroup/${cg_rel#/}"

snapshot() {
  python3 "$ROOT/oracle/snapshot.py" --output "$EVIDENCE/$1.json" --pins "$CGROUP_PINS"
}

drop_cache() {
  python3 "$ROOT/data/drop_cache.py" "$1"
}

wait_low_memory() {
  for _ in $(seq 1 100); do
    [ "$(cat "$CG/memory.current")" -lt $((1024 * 1024 * 1024)) ] && return 0
    sleep 0.1
  done
  return 1
}

prepare_b_output() {
  rm -rf "$B_OUTPUT_ROOT"
  install -d -o "$B_SERVICE_USER" -g "$B_SERVICE_USER" -m 755 "$B_OUTPUT_ROOT"
}

run_b() {
  local label=$1
  local expected=$2
  drop_cache "$B_INPUT_PATH"
  if [ "$A_ACTIVE" = 0 ]; then
    wait_low_memory || fail "${label}_cache_not_released"
  fi
  prepare_b_output
  snapshot "${label}_before"
  set +e
  setpriv --reuid="$B_SERVICE_USER" --regid="$B_SERVICE_USER" --init-groups \
    "$B_PUBLIC_ROOT/run.sh" >"$EVIDENCE/${label}.stdout" 2>"$EVIDENCE/${label}.stderr"
  B_RC=$?
  set -e
  printf '%s\n' "$B_RC" >"$EVIDENCE/${label}.rc"
  snapshot "${label}_after"
  for name in rank_report.json iteration_metrics.csv rank_progress.json; do
    [ -f "$B_OUTPUT_ROOT/$name" ] || fail "${label}_missing_${name}"
  done
  cp "$B_OUTPUT_ROOT/rank_report.json" "$EVIDENCE/${label}_report.json"
  cp "$B_OUTPUT_ROOT/iteration_metrics.csv" "$EVIDENCE/${label}_metrics.csv"
  cp "$B_OUTPUT_ROOT/rank_progress.json" "$EVIDENCE/${label}_progress.json"
  if [ "$expected" = met ]; then
    [ "$B_RC" -eq 0 ] || fail "${label}_unexpected_rc_${B_RC}"
    CHECK_B_OUTPUT_ROOT="$B_OUTPUT_ROOT" bash "$ROOT/eval/task_check_b.sh" >"$EVIDENCE/${label}_task.txt" || fail "${label}_validation_failed"
  else
    [ "$B_RC" -eq 75 ] || fail "${label}_unexpected_rc_${B_RC}"
    python3 - "$B_OUTPUT_ROOT/rank_report.json" <<'PY' >"$EVIDENCE/${label}_validation.txt"
import json
import pathlib
import sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert data["status"] == "complete" and data["completed_iterations"] == 4
assert data["edges_valid"] is True and data["slo_met"] is False
print("JOINT_GRAPH_VALID=1")
PY
  fi
}

echo "PHASE=preflight"
bash "$ROOT/preflight.sh" | tee "$EVIDENCE/preflight.txt" || fail preflight_failed
cp "$CGROUP_PINS" "$EVIDENCE/cgroup_pins.json"
printf '%s\n' \
  "PREDECLARED_BUDGET_SECONDS=$B_MAX_ELAPSED_SECONDS" \
  "PREDECLARED_MIN_SLOWDOWN_RATIO=$ORACLE_MIN_SLOWDOWN_RATIO" \
  "PREDECLARED_MAX_RECOVERY_RATIO=$ORACLE_MAX_RECOVERY_RATIO" \
  "BASELINE_TRIALS=$ORACLE_BASELINE_TRIALS" \
  "A_ALONE_OBSERVATIONS=2" \
  "JOINT_TRIALS=$ORACLE_JOINT_TRIALS" \
  "RECOVERY_TRIALS=$ORACLE_RECOVERY_TRIALS" \
  >"$EVIDENCE/predeclared_thresholds.txt"
snapshot initial

echo "PHASE=b_alone_calibration"
for trial in $(seq 1 "$ORACLE_BASELINE_TRIALS"); do
  run_b "baseline_$trial" met
done
drop_cache "$B_INPUT_PATH"
wait_low_memory || fail baseline_memory_not_released

echo "PHASE=a_alone_calibration"
drop_cache "$A_INPUT_PATH"
bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/start_a.txt" || fail a_start_failed
A_ACTIVE=1
ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$ready" = 1 ] || fail a_readiness_failed
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/capture_a_trust.txt" || fail a_trust_failed
cp "$A_TRUST_FILE" "$EVIDENCE/a_trust.json"
cp "$A_RUN_ROOT/checkpoint_ledger.jsonl" "$EVIDENCE/a_alone_ledger.jsonl"
snapshot a_healthy

echo "PHASE=joint_trials"
for trial in $(seq 1 "$ORACLE_JOINT_TRIALS"); do
  run_b "joint_$trial" miss
  bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_after_joint_${trial}.txt" || fail "a_peer_failed_after_joint_${trial}"
done
cp "$A_RUN_ROOT/checkpoint_ledger.jsonl" "$EVIDENCE/a_checkpoint_ledger.jsonl"
snapshot after_joint

echo "PHASE=normal_release"
bash "$ROOT/a/stop_a.sh" | tee "$EVIDENCE/stop_a.txt" || fail a_normal_release_failed
A_ACTIVE=0
cp "$A_RUN_ROOT/stopped.json" "$EVIDENCE/a_stopped.json"
drop_cache "$A_INPUT_PATH"
drop_cache "$B_INPUT_PATH"
wait_low_memory || fail release_memory_not_recovered
snapshot after_release

echo "PHASE=recovery_trials"
for trial in $(seq 1 "$ORACLE_RECOVERY_TRIALS"); do
  run_b "recovery_$trial" met
done
snapshot final

python3 "$ROOT/oracle/analyze_trials.py" "$EVIDENCE" \
  --baseline-trials "$ORACLE_BASELINE_TRIALS" \
  --joint-trials "$ORACLE_JOINT_TRIALS" \
  --recovery-trials "$ORACLE_RECOVERY_TRIALS" \
  --deadline "$B_MAX_ELAPSED_SECONDS" \
  --min-slowdown "$ORACLE_MIN_SLOWDOWN_RATIO" \
  --max-recovery-ratio "$ORACLE_MAX_RECOVERY_RATIO" \
  --min-pgscan "$ORACLE_MIN_PGSCAN_PAGES" \
  --min-refault "$ORACLE_MIN_REFAULT_PAGES" \
  --min-memory-psi-us "$ORACLE_MIN_MEMORY_PSI_US" \
  --max-cpu-pressure-fraction "$ORACLE_MAX_CPU_PRESSURE_FRACTION" \
  --max-io-full-fraction "$ORACLE_MAX_IO_FULL_FRACTION" \
  | tee "$EVIDENCE/analysis.txt" || fail trial_analysis_failed

REPORTED=1
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_IDENTITY_RETAINED=1 A_PROGRESS=1 THROUGHPUT_SEPARATION=1 MEMORY_PSI=1 RECLAIM=1 REFAULT=1 SWAP_BOUNDED=1 CPU_EXCLUDED=1 STORAGE_EXCLUDED=1 LOCKS_EXCLUDED=1 INPUTS_FIXED=1 B_RECOVERY_OK=1 RESOURCE=memory_capacity REASON=reclaim_refault_throughput_collapse"
trap - EXIT
exit 0
