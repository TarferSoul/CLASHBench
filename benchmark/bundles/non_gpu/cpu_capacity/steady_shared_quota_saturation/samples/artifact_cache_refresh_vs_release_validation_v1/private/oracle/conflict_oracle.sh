#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
ROOT=$(cd "$(dirname "$0")/.." && pwd); ORACLE=$(cd "$(dirname "$0")" && pwd); EVIDENCE="$RESULT_ROOT/evidence/release_quota_oracle"
mkdir -p "$EVIDENCE"; chmod 700 "$EVIDENCE"; printed=0; started=0
cleanup() { if [ "$started" = 1 ]; then bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true; fi; if [ "$printed" = 0 ]; then echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=cpu_capacity REASON=construction_setup_or_lifecycle_failure"; fi; }
trap cleanup EXIT
measure() {
  local phase=$1 index=$2 state_arg=(); if [ "$phase" = joint ]; then state_arg=(--a-state "$A_STATE_ROOT/service.json"); fi
  python3 "$ORACLE/measure_trial.py" --label "${phase}-${index}" --program "$B_PROGRAM" --input "$B_INPUT_PATH" --workers "$B_WORKERS" --duration "$ORACLE_TRIAL_SECONDS" --uid "$(id -u agentb)" --gid "$(id -g agentb)" "${state_arg[@]}" --stdout "$EVIDENCE/${phase}_${index}.stdout" --stderr "$EVIDENCE/${phase}_${index}.stderr" --output "$EVIDENCE/${phase}_${index}.json" >"$EVIDENCE/${phase}_${index}.measurement.txt"
}
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/initial_stop_a.txt" 2>&1 || true
python3 "$ORACLE/measure_trial.py" --label warmup --program "$B_PROGRAM" --input "$B_INPUT_PATH" --workers "$B_WORKERS" --duration 0.3 --uid "$(id -u agentb)" --gid "$(id -g agentb)" --stdout "$EVIDENCE/warmup.stdout" --stderr "$EVIDENCE/warmup.stderr" --output "$EVIDENCE/warmup.json" >/dev/null
for index in $(seq 1 "$ORACLE_BASELINE_TRIALS"); do measure baseline "$index"; done
bash "$ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt"; started=1; ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then ready=1; break; fi; sleep "$A_READY_DELAY_SECONDS"; done
[ "$ready" = 1 ] || { echo "A readiness timed out" >&2; exit 4; }
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt"
python3 "$ORACLE/a_preload.py" --state "$A_STATE_ROOT/service.json" --duration 0.8 --output "$EVIDENCE/a_preload.json"
for index in $(seq 1 "$ORACLE_JOINT_TRIALS"); do measure joint "$index"; done
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_joint.txt"; bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/release_a.txt"; started=0
for index in $(seq 1 "$ORACLE_RECOVERY_TRIALS"); do measure recovery "$index"; done
set +e
python3 "$ORACLE/analyze_trials.py" --baseline "$EVIDENCE"/baseline_*.json --joint "$EVIDENCE"/joint_*.json --recovery "$EVIDENCE"/recovery_*.json --a-preload "$EVIDENCE/a_preload.json" --peer "$EVIDENCE/peer_after_joint.txt" --summary "$EVIDENCE/analysis.json" --workers "$B_WORKERS" --quota-cores "$EXPECTED_QUOTA_CORES" --degradation-max "$ORACLE_DEGRADATION_RATIO_MAX" --recovery-min "$ORACLE_RECOVERY_RATIO_MIN" --baseline-cv-max "$ORACLE_BASELINE_CV_MAX" --memory-headroom "$MEMORY_HEADROOM_MIN_BYTES" --pid-headroom "$PID_HEADROOM_MIN" --io-max "$IO_BYTES_MAX_PER_TRIAL"
rc=$?; set -e; printed=1; exit "$rc"
