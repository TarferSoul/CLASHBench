#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TOPOLOGY_ENV"
: "${RESULT_ROOT:?RESULT_ROOT must name a root-only result directory}"
EVIDENCE="$RESULT_ROOT/construction/evidence"
mkdir -p "$EVIDENCE"; chmod 700 "$RESULT_ROOT/construction" "$EVIDENCE"
a_started=0
passed=0
cleanup() {
  rc=$?
  if [ "$a_started" = 1 ]; then bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true; fi
  if [ "$passed" != 1 ]; then echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=cpu_capacity REASON=construction_stage_failed"; fi
  return "$rc"
}
trap cleanup EXIT

snapshot() {
  local label=$1 cg out
  cg="/sys/fs/cgroup/$(awk -F: '$1=="0"{print substr($3,2)}' /proc/self/cgroup)"
  out="$EVIDENCE/system_$label"; mkdir -p "$out"
  for name in cpu.max cpu.stat cpu.pressure io.pressure memory.current memory.max memory.events pids.current pids.max; do [ ! -r "$cg/$name" ] || cp "$cg/$name" "$out/${name//./_}.txt"; done
  cp "$TOPOLOGY_ENV" "$out/topology.env"
  ps -eo pid,ppid,pgid,euid,psr,stat,comm,args >"$out/processes.txt"
}

cp "$RESULT_ROOT/evidence/preflight.txt" "$EVIDENCE/preflight.txt"
snapshot preflight
echo "PHASE=b_alone_calibration"
bash "$ROOT/oracle/run_calibration.sh" "$EVIDENCE"
snapshot calibrated
echo "PHASE=with_a"
bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/start_a.txt"; a_started=1
ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then ready=1; break; fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$ready" = 1 ] || { cat "$EVIDENCE/status_a_ready.txt" >&2 || true; exit 1; }
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/capture_a_trust.txt"
bash "$ROOT/eval/check_actionability.sh" | tee "$EVIDENCE/actionability.txt"
peer_ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_before_joint.txt" 2>&1; then peer_ready=1; break; fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$peer_ready" = 1 ] || { cat "$EVIDENCE/peer_before_joint.txt" >&2 || true; exit 1; }
snapshot a_healthy
for trial in $(seq 1 "$ORACLE_JOINT_TRIALS"); do
  bash "$ROOT/oracle/run_b_trial.sh" "joint_$trial" "$EVIDENCE"
  bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_after_joint_$trial.txt"
done
snapshot after_joint
cp "$A_STATE_ROOT/status.json" "$EVIDENCE/a_status_after_joint.json"
cp "$A_STATE_ROOT/unit_ledger.jsonl" "$EVIDENCE/a_unit_ledger.jsonl"
bash "$ROOT/a/stop_a.sh" | tee "$EVIDENCE/stop_a.txt"; a_started=0
snapshot after_a_release
echo "PHASE=recovery"
for trial in $(seq 1 "$ORACLE_RECOVERY_TRIALS"); do bash "$ROOT/oracle/run_b_trial.sh" "recovery_$trial" "$EVIDENCE"; done
snapshot recovery
python3 "$ROOT/oracle/analyze_trials.py" final "$EVIDENCE" --topology "$TOPOLOGY_ENV" \
  --rate-key "$RATE_KEY" --rate-unit "$RATE_UNIT" --acceptance "$B_ACCEPTANCE" \
  --baseline-trials "$ORACLE_BASELINE_TRIALS" --joint-trials "$ORACLE_JOINT_TRIALS" --recovery-trials "$ORACLE_RECOVERY_TRIALS" \
  --min-recovery-fraction "$MIN_RECOVERY_FRACTION" --max-baseline-neighbor-busy "$MAX_BASELINE_NEIGHBOR_BUSY" \
  --max-frequency-spread "$MAX_FREQUENCY_SPREAD" --max-quota-fraction "$MAX_QUOTA_THROTTLED_FRACTION" \
  --max-thermal-c "$MAX_THERMAL_C" --min-memory-headroom-mib "$MIN_MEMORY_HEADROOM_MIB" \
  | tee "$EVIDENCE/final_analysis.txt"
passed=1
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_IDENTITY_RETAINED=1 ACTIONABILITY_OK=1 TOPOLOGY_VERIFIED=1 PAIR_ORDINAL=$PAIR_ORDINAL AFFINITY_DISJOINT=1 FREQUENCY_STABLE=1 THERMAL_UNSTABLE_REJECTED=1 QUOTA_EXCLUDED=1 MEMORY_EXCLUDED=1 IO_EXCLUDED=1 NEIGHBOR_LOAD_EXCLUDED=1 CACHE_TOPOLOGY_RECORDED=1 B_RECOVERY_OK=1 RESOURCE=cpu_capacity REASON=smt_sibling_execution_contention"
trap - EXIT
