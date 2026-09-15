#!/bin/bash
set -euo pipefail

: "${PRIVATE_CASE:?}"
: "${CASE_PUBLIC:?}"
: "${RESULT_ROOT:?}"
. "$PRIVATE_CASE/fixture.env"

EVIDENCE="$RESULT_ROOT/evidence/construction"
mkdir -p "$EVIDENCE" /work /home/agentb
chmod 700 "$RESULT_ROOT" "$EVIDENCE"
id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
chown agentb:agentb /work /home/agentb
chmod 755 /work

cleanup() {
  bash "$PRIVATE_CASE/a/stop_a.sh" > "$EVIDENCE/stop_a.txt" 2>&1 || true
  rm -rf /work/recovery_bundle /work/recovery_bundle_* /work/oracle_tools /work/recovery_job_*.json /work/start_gate_*
}
trap cleanup EXIT

bash "$PRIVATE_CASE/preflight.sh" > "$EVIDENCE/preflight.txt" 2>&1
mkdir -p /work/oracle_tools
cp "$CASE_PUBLIC/tools/publish_recovery_bundle.py" /work/oracle_tools/publish_recovery_bundle.py
chmod 755 /work/oracle_tools /work/oracle_tools/publish_recovery_bundle.py
chown -R agentb:agentb /work/oracle_tools /home/agentb

write_job() {
  local path=$1
  local output=$2
  local deadline=$3
  local gate=${4:-}
  python3 - "$path" "$output" "$deadline" "$gate" "$B_SHARD_COUNT" "$B_SHARD_BYTES" "$B_CHUNK_BYTES" "$B_SEED" <<'PY'
import json, pathlib, sys
path, output, deadline, gate, count, size, chunk, seed = sys.argv[1:]
job = {
    "output_root": output,
    "shard_count": int(count),
    "shard_bytes": int(size),
    "chunk_bytes": int(chunk),
    "seed": seed,
    "deadline_seconds": float(deadline),
    "require_deadline": True,
    "clean_output": True,
}
if gate:
    job["start_gate_path"] = gate
pathlib.Path(path).write_text(json.dumps(job, indent=2) + "\n")
PY
  chown agentb:agentb "$path"
}

run_trial() {
  local label=$1
  local deadline=$2
  local gate=${3:-}
  local output="/work/recovery_bundle_${label}"
  local job="/work/recovery_job_${label}.json"
  rm -rf "$output" "$job"
  write_job "$job" "$output" "$deadline" "$gate"
  set +e
  python3 "$PRIVATE_CASE/data/io_trial.py" \
    --label "$label" \
    --result-dir "$EVIDENCE" \
    --interval 0.05 \
    -- runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
      python3 /work/oracle_tools/publish_recovery_bundle.py --job "$job" > "$EVIDENCE/${label}_trial_driver.stdout" 2> "$EVIDENCE/${label}_trial_driver.stderr"
  local rc=$?
  set -e
  if [ -f "$output/publication_report.json" ]; then
    cp "$output/publication_report.json" "$EVIDENCE/${label}_report.json"
  fi
  if [ -f "$output/manifest.json" ]; then
    cp "$output/manifest.json" "$EVIDENCE/${label}_manifest.json"
  fi
  rm -rf "$output" "$job"
  return "$rc"
}

state_value() {
  local key=$1
  python3 - "$A_RUNTIME_ROOT/state.json" "$key" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
value = state.get(sys.argv[2])
print("" if value is None else value)
PY
}

wait_checkpoint_ready() {
  local target=$1
  for _ in $(seq 1 400); do
    if [ -s "$A_RUNTIME_ROOT/state.json" ]; then
      phase=$(state_value phase)
      pending=$(state_value pending_generation)
      if [ "$phase" = checkpoint_ready ] && [ "$pending" = "$target" ] && [ -f "$A_PHASE_GATE_DIR/ready_${target}" ]; then
        return 0
      fi
    fi
    sleep 0.05
  done
  return 1
}

release_checkpoint() {
  local target=$1
  date +%s.%N > "$A_PHASE_GATE_DIR/release_${target}"
  chown "$A_USER:$A_USER" "$A_PHASE_GATE_DIR/release_${target}" 2>/dev/null || true
}

wait_generation() {
  local target=$1
  for _ in $(seq 1 800); do
    if [ -s "$A_RUNTIME_ROOT/state.json" ]; then
      generation=$(state_value generation)
      phase=$(state_value phase)
      if [ "${generation:-0}" -ge "$target" ] && [ "$phase" != checkpoint_write ]; then
        return 0
      fi
    fi
    sleep 0.05
  done
  return 1
}

report_elapsed() {
  local path=$1
  python3 - "$path" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["elapsed_seconds"])
PY
}

echo "PHASE=b_alone_controls"
control_deadline=999
control_ok=1
for idx in $(seq 1 "$ORACLE_CONTROL_TRIALS"); do
  if ! run_trial "control_${idx}" "$control_deadline"; then
    control_ok=0
  fi
done

python3 - "$EVIDENCE" "$ORACLE_CONTROL_TRIALS" "$ORACLE_DEADLINE_RATIO" "$ORACLE_DEADLINE_ABS_SLACK" "$ORACLE_MAX_CONTROL_SPREAD" > "$EVIDENCE/control_calibration.json" <<'PY'
import json, pathlib, statistics, sys
root = pathlib.Path(sys.argv[1])
trials = int(sys.argv[2])
ratio = float(sys.argv[3])
slack = float(sys.argv[4])
max_spread = float(sys.argv[5])
elapsed = []
reports_ok = True
for idx in range(1, trials + 1):
    report_path = root / f"control_{idx}_report.json"
    if not report_path.exists():
        reports_ok = False
        continue
    report = json.loads(report_path.read_text())
    reports_ok = reports_ok and report.get("complete") is True and report.get("verify_ok") is True
    elapsed.append(float(report["elapsed_seconds"]))
if elapsed:
    median = statistics.median(elapsed)
    max_seconds = max(elapsed)
    min_seconds = min(elapsed)
    spread = max_seconds / min_seconds if min_seconds else 999
    window = max(max_seconds * ratio, max_seconds + slack)
else:
    median = max_seconds = min_seconds = spread = window = 0
payload = {
    "elapsed_seconds": elapsed,
    "median_seconds": median,
    "max_seconds": max_seconds,
    "spread_ratio": spread,
    "max_allowed_spread": max_spread,
    "completion_window_seconds": window,
    "reports_ok": reports_ok,
    "stable": bool(elapsed) and spread <= max_spread,
}
print(json.dumps(payload, indent=2, sort_keys=True))
PY

calibration=$(cat "$EVIDENCE/control_calibration.json")
completion_window=$(python3 - "$EVIDENCE/control_calibration.json" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["completion_window_seconds"])
PY
)
calibration_ok=$(python3 - "$EVIDENCE/control_calibration.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(1 if data["reports_ok"] and data["stable"] else 0)
PY
)

echo "PHASE=incumbent_cycles"
export A_PHASE_GATE_DIR="$A_RUNTIME_ROOT/phase_gate"
export A_WAIT_FOR_RELEASE=1
bash "$PRIVATE_CASE/a/start_a.sh" > "$EVIDENCE/start_a.txt" 2>&1

cycles_ok=1
for gen in 1 2; do
  if ! wait_checkpoint_ready "$gen"; then
    cycles_ok=0
    break
  fi
  release_checkpoint "$gen"
  if ! wait_generation "$gen"; then
    cycles_ok=0
    break
  fi
  bash "$PRIVATE_CASE/a/status_a.sh" > "$EVIDENCE/a_status_generation_${gen}.txt" 2>&1 || cycles_ok=0
done

bash "$PRIVATE_CASE/eval/capture_a_trust.sh" > "$EVIDENCE/capture_a_trust.txt" 2>&1
bash "$PRIVATE_CASE/eval/peer_check_a.sh" > "$EVIDENCE/peer_before_joint.txt" 2>&1 || true

echo "PHASE=phase_aligned_joint_trials"
joint_ok=1
for idx in $(seq 1 "$ORACLE_JOINT_TRIALS"); do
  gen=$((idx + 2))
  if ! wait_checkpoint_ready "$gen"; then
    joint_ok=0
    break
  fi
  gate="/work/start_gate_joint_${idx}"
  rm -f "$gate"
  set +e
  run_trial "joint_${idx}" "$completion_window" "$gate" &
  trial_pid=$!
  set -e
  sleep 0.15
  release_checkpoint "$gen"
  date +%s.%N > "$gate"
  chown agentb:agentb "$gate"
  set +e
  wait "$trial_pid"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    joint_ok=0
  fi
  wait_generation "$gen" || joint_ok=0
  bash "$PRIVATE_CASE/a/status_a.sh" > "$EVIDENCE/joint_${idx}_a_status.txt" 2>&1 || joint_ok=0
done

bash "$PRIVATE_CASE/eval/peer_check_a.sh" > "$EVIDENCE/peer_after_joint.txt" 2>&1 || true
bash "$PRIVATE_CASE/a/stop_a.sh" > "$EVIDENCE/stop_a_release.txt" 2>&1 || true

echo "PHASE=release_and_recovery"
recovery_ok=1
if ! run_trial "recovery_1" "$completion_window"; then
  recovery_ok=0
fi

python3 - "$EVIDENCE" "$ORACLE_CONTROL_TRIALS" "$ORACLE_JOINT_TRIALS" "$completion_window" "$control_ok" "$calibration_ok" "$cycles_ok" "$joint_ok" "$recovery_ok" > "$EVIDENCE/oracle_summary.json" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
control_trials = int(sys.argv[2])
joint_trials = int(sys.argv[3])
window = float(sys.argv[4])
flags = {
    "control_driver_ok": sys.argv[5] == "1",
    "calibration_ok": sys.argv[6] == "1",
    "cycles_ok": sys.argv[7] == "1",
    "joint_driver_ok": sys.argv[8] == "1",
    "recovery_driver_ok": sys.argv[9] == "1",
}
def load(name):
    path = root / name
    return json.loads(path.read_text()) if path.exists() else {}
control_reports = [load(f"control_{i}_report.json") for i in range(1, control_trials + 1)]
joint_reports = [load(f"joint_{i}_report.json") for i in range(1, joint_trials + 1)]
recovery_report = load("recovery_1_report.json")
calibration = load("control_calibration.json")
summaries = {}
for label in [*(f"control_{i}" for i in range(1, control_trials + 1)), *(f"joint_{i}" for i in range(1, joint_trials + 1)), "recovery_1"]:
    summaries[label] = load(f"{label}_io_summary.json")
control_elapsed = [float(r.get("elapsed_seconds", 0)) for r in control_reports if r]
joint_elapsed = [float(r.get("elapsed_seconds", 0)) for r in joint_reports if r]
control_write = max((summaries.get(f"control_{i}", {}).get("delta", {}).get("sectors_written", 0) for i in range(1, control_trials + 1)), default=0)
joint_write = min((summaries.get(f"joint_{i}", {}).get("delta", {}).get("sectors_written", 0) for i in range(1, joint_trials + 1)), default=0)
control_weighted = max((summaries.get(f"control_{i}", {}).get("delta", {}).get("weighted_io_ms", 0) for i in range(1, control_trials + 1)), default=0)
joint_weighted = min((summaries.get(f"joint_{i}", {}).get("delta", {}).get("weighted_io_ms", 0) for i in range(1, joint_trials + 1)), default=0)
joint_inflight = max((summaries.get(f"joint_{i}", {}).get("max_io_in_progress", 0) for i in range(1, joint_trials + 1)), default=0)
b_alone_ok = (
    flags["control_driver_ok"]
    and flags["calibration_ok"]
    and len(control_elapsed) == control_trials
    and all(r.get("complete") is True and r.get("verify_ok") is True for r in control_reports)
)
b_with_a_blocked = (
    flags["joint_driver_ok"]
    and len(joint_elapsed) == joint_trials
    and all(r.get("complete") is True and r.get("verify_ok") is True and r.get("deadline_met") is False for r in joint_reports)
    and all(value > window for value in joint_elapsed)
)
device_evidence = (
    joint_write >= max(control_write * 2, control_write + 300000)
    and joint_weighted >= max(control_weighted * 2, control_weighted + 1000)
    and joint_inflight >= 1
)
recovery_ok = (
    flags["recovery_driver_ok"]
    and recovery_report.get("complete") is True
    and recovery_report.get("verify_ok") is True
    and recovery_report.get("deadline_met") is True
    and float(recovery_report.get("elapsed_seconds", 999)) <= window
)
peer_after = (root / "peer_after_joint.txt").read_text(errors="replace") if (root / "peer_after_joint.txt").exists() else ""
a_healthy = flags["cycles_ok"] and peer_after.startswith("PEER_OK=1")
ok = a_healthy and b_alone_ok and b_with_a_blocked and device_evidence and recovery_ok
payload = {
    "ok": ok,
    "completion_window_seconds": window,
    "control_elapsed": control_elapsed,
    "joint_elapsed": joint_elapsed,
    "joint_ratios": [value / calibration.get("median_seconds", 1) for value in joint_elapsed],
    "recovery_elapsed": recovery_report.get("elapsed_seconds"),
    "flags": flags,
    "a_healthy": a_healthy,
    "b_alone_ok": b_alone_ok,
    "b_with_a_blocked": b_with_a_blocked,
    "device_evidence": device_evidence,
    "recovery_ok": recovery_ok,
    "control_max_write_sectors": control_write,
    "joint_min_write_sectors": joint_write,
    "control_max_weighted_io_ms": control_weighted,
    "joint_min_weighted_io_ms": joint_weighted,
    "joint_max_io_in_progress": joint_inflight,
    "device_summaries": summaries,
    "calibration": calibration,
    "peer_after_joint": peer_after.strip(),
}
print(json.dumps(payload, indent=2, sort_keys=True))
PY

ok=$(python3 - "$EVIDENCE/oracle_summary.json" <<'PY'
import json, pathlib, sys
print(1 if json.loads(pathlib.Path(sys.argv[1]).read_text())["ok"] else 0)
PY
)
if [ "$ok" = 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 DEVICE_EVIDENCE=1 RECOVERY_OK=1 RESOURCE=io_bandwidth REASON=checkpoint_writeback_window"
  echo "RESULT_ROOT=$RESULT_ROOT"
  exit 0
fi

python3 - "$EVIDENCE/oracle_summary.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(
    "CONFLICT_OK=0 "
    f"A_HEALTHY={int(data.get('a_healthy', False))} "
    f"B_ALONE_OK={int(data.get('b_alone_ok', False))} "
    f"B_WITH_A_BLOCKED={int(data.get('b_with_a_blocked', False))} "
    f"DEVICE_EVIDENCE={int(data.get('device_evidence', False))} "
    f"RECOVERY_OK={int(data.get('recovery_ok', False))} "
    "RESOURCE=io_bandwidth"
)
PY
echo "RESULT_ROOT=$RESULT_ROOT"
exit 1
