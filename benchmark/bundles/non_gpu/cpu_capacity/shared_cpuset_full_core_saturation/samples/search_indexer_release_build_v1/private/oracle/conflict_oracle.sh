#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
. "$CPU_ENV"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
EVIDENCE="$RESULT_ROOT/evidence/cpu_capacity"
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"
printed=0
started=0
cleanup() {
  if [ "$started" = 1 ]; then bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true; fi
  if [ "$printed" = 0 ]; then echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=cpu_capacity REASON=construction_setup_or_lifecycle_failure"; fi
}
trap cleanup EXIT
run_trial() {
  local phase=$1 index=$2 port=${3:-0}
  python3 "$HERE/run_trial.py" --label "$phase-$index" --metrics "$EVIDENCE/${phase}_${index}.json" \
    --stdout "$EVIDENCE/${phase}_${index}.stdout" --stderr "$EVIDENCE/${phase}_${index}.stderr" \
    --program "$B_PROGRAM" --input "$B_INPUT" --job "$B_JOB" --output-dir "$B_OUTPUT_DIR/${phase}-${index}" \
    --seconds "$B_TRIAL_SECONDS" --uid "$SERVICE_UID" --gid "$SERVICE_GID" --cpus "$CPU_LIST" --a-port "$port" \
    >"$EVIDENCE/${phase}_${index}.measurement.txt"
}
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/initial_stop_a.txt" 2>&1 || true
cat "$B_INPUT" >/dev/null
for index in $(seq 1 "$B_BASELINE_TRIALS"); do run_trial baseline "$index"; done
bash "$ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt"
started=1
ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then ready=1; break; fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$ready" = 1 ] || { echo "A readiness timed out" >&2; exit 4; }
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt"
for index in $(seq 1 "$B_JOINT_TRIALS"); do run_trial joint "$index" "$A_PORT"; done
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_joint.txt"
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/release_a.txt"
started=0
for index in $(seq 1 "$B_RECOVERY_TRIALS"); do run_trial recovery "$index"; done
set +e
python3 "$HERE/analyze_trials.py" --baseline "$EVIDENCE"/baseline_*.json --joint "$EVIDENCE"/joint_*.json \
  --recovery "$EVIDENCE"/recovery_*.json --topology "$RESULT_ROOT/evidence/cpu_topology.json" \
  --peer "$EVIDENCE/peer_after_joint.txt" --summary "$EVIDENCE/analysis.json" \
  --degradation-ratio-max "$B_DEGRADATION_RATIO_MAX" --recovery-ratio-min "$B_RECOVERY_RATIO_MIN" \
  --baseline-cv-max "$B_BASELINE_CV_MAX" --quota-headroom-ratio-min "$QUOTA_HEADROOM_RATIO_MIN" \
  --memory-headroom-min "$MEMORY_HEADROOM_MIN_BYTES" --pid-headroom-min "$PID_HEADROOM_MIN"
rc=$?
set -e
printed=1
exit "$rc"
