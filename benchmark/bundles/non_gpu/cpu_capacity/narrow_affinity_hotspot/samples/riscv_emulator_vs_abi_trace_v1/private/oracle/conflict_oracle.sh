#!/usr/bin/env bash
set -euo pipefail
PRIVATE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"
. "$LANE_CONFIG"
test "$(id -u)" = 0
: "${RESULT_ROOT:?}"
EVIDENCE="$RESULT_ROOT/evidence/riscv_lane"
TRIAL_ROOT=/dev/shm/riscv-lane-trials
b_uid=$(id -u "$SERVICE_USER")
b_gid=$(id -g "$SERVICE_USER")
started=0
printed=0
monitor_pid=
cleanup() {
  [ -z "$monitor_pid" ] || { touch "$EVIDENCE/monitor.stop" 2>/dev/null || true; wait "$monitor_pid" 2>/dev/null || true; }
  [ "$started" = 0 ] || bash "$PRIVATE_ROOT/a/stop_a.sh" >>"$EVIDENCE/cleanup_stop.txt" 2>&1 || true
  rm -rf "$TRIAL_ROOT"
  [ "$printed" = 1 ] || echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=cpu_capacity REASON=construction_setup_or_lifecycle_failure"
}
trap cleanup EXIT
rm -rf "$EVIDENCE" "$TRIAL_ROOT"
install -d -o root -g root -m 700 "$EVIDENCE"
install -d -o "$b_uid" -g "$b_gid" -m 700 "$TRIAL_ROOT"
bash "$PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/initial_stop.txt" 2>&1 || true
run_rate() {
  local name=$1
  local seconds=$2
  local out="$TRIAL_ROOT/$name.json"
  setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
    env -i PATH="$FIXED_PATH" HOME=/work \
    "$LANE_WRAPPER" python3 "$B_PROGRAM" --input "$B_INPUT" --rate-seconds "$seconds" --rate-output "$out" \
    >"$EVIDENCE/$name.stdout" 2>"$EVIDENCE/$name.stderr"
  cp "$out" "$EVIDENCE/$name.json"
  chmod 600 "$EVIDENCE/$name.json"
}
run_delivery() {
  local name=$1
  local scratch="$TRIAL_ROOT/$name"
  rm -rf "$scratch"
  install -d -o "$b_uid" -g "$b_gid" -m 700 "$scratch"
  set +e
  setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
    env -i PATH="$FIXED_PATH" HOME=/work \
    "$LANE_WRAPPER" python3 "$B_PROGRAM" --input "$B_INPUT" --job "$B_JOB" --output-dir "$scratch" \
    >"$EVIDENCE/$name.stdout" 2>"$EVIDENCE/$name.stderr"
  local rc=$?
  set -e
  cp "$scratch/abi_trace_report.json" "$EVIDENCE/$name.json"
  printf '%s\n' "$rc" >"$EVIDENCE/$name.rc"
}
run_rate warm 0.30
for index in $(seq 1 "$ORACLE_BASELINE_TRIALS"); do run_rate "baseline_$index" "$B_RATE_SECONDS"; done
python3 - "$EVIDENCE" "$B_JOB" "$B_INPUT" "$CPU_LIST" "$B_AGENT_WINDOW_SECONDS" "$B_AGENT_TARGET_FRACTION" <<'PY'
import hashlib, json, pathlib, statistics, sys
root, job_path, source, lane, window, fraction = sys.argv[1:]
rates = [json.loads(path.read_text())["batches_per_second"] for path in sorted(pathlib.Path(root).glob("baseline_*.json"))]
job = {
    "schema": "abi-trace-job-v1",
    "input_digest": hashlib.sha256(pathlib.Path(source).read_bytes()).hexdigest(),
    "lane_cpus": [int(x) for x in lane.split(",")],
    "required_batches": max(1, int(statistics.median(rates) * float(window) * float(fraction))),
    "deadline_seconds": float(window),
    "calibrated_median_batches_per_second": statistics.median(rates),
    "target_fraction": float(fraction),
}
pathlib.Path(job_path).write_text(json.dumps(job, sort_keys=True, indent=2) + "\n")
pathlib.Path(root, "delivery_policy.json").write_text(json.dumps(job, sort_keys=True, indent=2) + "\n")
PY
chown "$SERVICE_USER:$SERVICE_USER" "$B_JOB"
run_delivery baseline_delivery
bash "$PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt"
started=1
ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if bash "$PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then ready=1; break; fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$ready" = 1 ] || { echo "CONFLICT_OK=0 reason=a_readiness_timeout"; printed=1; exit 1; }
bash "$PRIVATE_ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt"
cp "$A_TRUST_PATH" "$EVIDENCE/a_trust.json"
a_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_TRUST_PATH")
python3 "$PRIVATE_ROOT/oracle/snapshot_system.py" --output "$EVIDENCE/joint_before.json" --a-pid "$a_pid" --phase joint_before
rm -f "$EVIDENCE/monitor.stop"
python3 "$PRIVATE_ROOT/oracle/monitor_joint.py" --a-pid "$a_pid" --b-program "$B_PROGRAM" --b-uid "$b_uid" --lane "$CPU_LIST" --stop "$EVIDENCE/monitor.stop" --output "$EVIDENCE/joint_monitor.json" &
monitor_pid=$!
for index in $(seq 1 "$ORACLE_JOINT_TRIALS"); do run_rate "joint_$index" "$B_RATE_SECONDS"; done
run_delivery joint_delivery
touch "$EVIDENCE/monitor.stop"
wait "$monitor_pid"
monitor_pid=
python3 "$PRIVATE_ROOT/oracle/snapshot_system.py" --output "$EVIDENCE/joint_after.json" --a-pid "$a_pid" --phase joint_after
bash "$PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_joint.txt"
cp "$A_RUNTIME_ROOT/state.json" "$EVIDENCE/a_state_after.json"
bash "$PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a.txt"
started=0
for index in $(seq 1 "$ORACLE_RECOVERY_TRIALS"); do run_rate "recovery_$index" "$B_RATE_SECONDS"; done
run_delivery recovery_delivery
set +e
python3 "$PRIVATE_ROOT/oracle/analyze_rate_trials.py" \
  --evidence "$EVIDENCE" --trust "$A_TRUST_PATH" --state-after "$EVIDENCE/a_state_after.json" \
  --peer "$EVIDENCE/peer_after_joint.txt" --before "$EVIDENCE/joint_before.json" \
  --after "$EVIDENCE/joint_after.json" --monitor "$EVIDENCE/joint_monitor.json" \
  --lane "$CPU_LIST" --available "$AVAILABLE_CPUS" --degradation-max "$DEGRADATION_RATIO_MAX" \
  --recovery-min "$RECOVERY_RATIO_MIN" --cv-max "$BASELINE_CV_MAX" \
  --min-busy "$MIN_LANE_BUSY_FRACTION" --max-throttled "$MAX_THROTTLED_USEC_DELTA" \
  --min-runnable "$MIN_RUNNABLE_OVERLAP_SAMPLES" --output "$EVIDENCE/analysis.json"
rc=$?
set -e
printed=1
trap - EXIT
rm -rf "$TRIAL_ROOT"
exit "$rc"
