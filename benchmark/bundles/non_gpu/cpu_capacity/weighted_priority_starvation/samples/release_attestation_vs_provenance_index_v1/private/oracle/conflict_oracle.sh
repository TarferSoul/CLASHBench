#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
. "$SCHED_ENV"

EVIDENCE="$RESULT_ROOT/evidence/release_priority_trials"
PROBE_RUNTIME="/run/${SCHEDULER_NAMESPACE}-probes"
mkdir -p "$EVIDENCE"
chmod 700 "$EVIDENCE"
rm -rf "$PROBE_RUNTIME"
install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 700 "$PROBE_RUNTIME"
printed=0
a_started=0

cleanup() {
  if [ "$a_started" = 1 ]; then
    PRIVATE_CASE="$PRIVATE_CASE" bash "$PRIVATE_CASE/a/stop_a.sh" >"$EVIDENCE/cleanup_a.txt" 2>&1 || true
  fi
  rm -rf "$PROBE_RUNTIME"
  if [ "$printed" = 0 ]; then
    echo 'CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=cpu_capacity REASON=construction_setup_or_lifecycle_failure'
  fi
}
trap cleanup EXIT

run_trial() {
  local phase=$1
  local index=$2
  local trial_root="$PROBE_RUNTIME/${phase}_${index}"
  rm -rf "$trial_root"
  install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 700 "$trial_root"
  python3 "$PRIVATE_CASE/oracle/run_probe.py" \
    --label "$phase-$index" --metrics "$EVIDENCE/${phase}_${index}.json" \
    --stdout "$EVIDENCE/${phase}_${index}.stdout" --stderr "$EVIDENCE/${phase}_${index}.stderr" \
    --report "$trial_root/report.json" --launcher "$PRIVATE_CASE/priority_launch.py" \
    --nice "$B_NICE" --a-pid-file "$A_PID_FILE" --lane-cpu "$LANE_CPU" --uid "$AGENT_UID" --gid "$AGENT_GID" \
    --pid-file "$EVIDENCE/${phase}_${index}.pid" -- \
    "$B_PROGRAM" --job "$B_JOB" --output "$trial_root" --cpu "$LANE_CPU" --probe-seconds "$PROBE_SECONDS"
}

PRIVATE_CASE="$PRIVATE_CASE" bash "$PRIVATE_CASE/a/stop_a.sh" >"$EVIDENCE/initial_a_stop.txt" 2>&1 || true
for index in $(seq 1 "$BASELINE_TRIALS"); do run_trial baseline "$index"; done

PRIVATE_CASE="$PRIVATE_CASE" AGENT_UID="$AGENT_UID" AGENT_GID="$AGENT_GID" \
  bash "$PRIVATE_CASE/a/start_a.sh" >"$EVIDENCE/start_a.txt"
a_started=1
ready=0
for _ in $(seq 1 80); do
  if PRIVATE_CASE="$PRIVATE_CASE" AGENT_UID="$AGENT_UID" bash "$PRIVATE_CASE/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
[ "$ready" = 1 ] || { echo 'A readiness timeout' >&2; exit 4; }
PRIVATE_CASE="$PRIVATE_CASE" bash "$PRIVATE_CASE/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt"

for index in $(seq 1 "$JOINT_TRIALS"); do run_trial joint "$index"; done
PRIVATE_CASE="$PRIVATE_CASE" bash "$PRIVATE_CASE/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_joint.txt" 2>&1 || true
PRIVATE_CASE="$PRIVATE_CASE" bash "$PRIVATE_CASE/a/stop_a.sh" >"$EVIDENCE/release_a.txt"
a_started=0

for index in $(seq 1 "$RECOVERY_TRIALS"); do run_trial recovery "$index"; done

set +e
python3 "$PRIVATE_CASE/oracle/analyze_trials.py" \
  --evidence "$EVIDENCE" --peer "$EVIDENCE/peer_after_joint.txt" --summary "$EVIDENCE/analysis.json" \
  --baseline-count "$BASELINE_TRIALS" --joint-count "$JOINT_TRIALS" --recovery-count "$RECOVERY_TRIALS" \
  --a-nice "$A_NICE" --b-nice "$B_NICE" --a-weight "$A_CFS_WEIGHT" --b-weight "$B_CFS_WEIGHT" --degradation-max "$DEGRADATION_RATIO_MAX" \
  --recovery-min "$RECOVERY_RATIO_MIN" --b-share-max "$B_SHARE_MAX" \
  --usage-ratio-min "$A_TO_B_USAGE_RATIO_MIN" --quota-headroom-min "$ROOT_QUOTA_HEADROOM_MIN"
rc=$?
set -e
printed=1
exit "$rc"
