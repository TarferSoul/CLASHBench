#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$CASE_PRIVATE_ROOT/fixture.env"
: "${RESULT_ROOT:?set RESULT_ROOT}"

EVIDENCE="$RESULT_ROOT/construction/evidence"
LIVE="$RESULT_ROOT/construction/live"
mkdir -p "$EVIDENCE" "$LIVE"
chmod 700 "$RESULT_ROOT" "$RESULT_ROOT/construction" "$EVIDENCE" "$LIVE"
A_STARTED=0
A_HEALTHY=0
B_ALONE_OK=0
B_WITH_A_BLOCKED=0

cleanup() {
  set +e
  [ ! -e "$A_STDOUT" ] || cp "$A_STDOUT" "$EVIDENCE/a_service.stdout"
  [ ! -e "$A_EVENT_LOG" ] || cp "$A_EVENT_LOG" "$EVIDENCE/a_events.jsonl"
  [ "$A_STARTED" = 0 ] || bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a_cleanup.txt" 2>&1 || true
}
trap cleanup EXIT

fail() {
  local reason=$1
  echo "CONFLICT_OK=0 A_HEALTHY=$A_HEALTHY B_ALONE_OK=$B_ALONE_OK B_WITH_A_BLOCKED=$B_WITH_A_BLOCKED RESOURCE=cpu_capacity REASON=$reason"
  exit 1
}

cg_rel=$(awk -F: '$1=="0" {print $3}' /proc/self/cgroup)
CG_PATH="/sys/fs/cgroup${cg_rel}"
CG_PATH=${CG_PATH%/}
[ -d "$CG_PATH" ] || CG_PATH=/sys/fs/cgroup

stat_value() {
  awk -v key="$1" '$1 == key {print $2}' "$CG_PATH/cpu.stat"
}

pressure_snapshot() {
  local label=$1
  {
    printf 'cpu.max '; cat "$CG_PATH/cpu.max"
    echo 'cpu.stat'; cat "$CG_PATH/cpu.stat"
    echo 'cpu.pressure'; cat "$CG_PATH/cpu.pressure" 2>/dev/null || true
    echo 'io.pressure'; cat "$CG_PATH/io.pressure" 2>/dev/null || true
    echo 'io.stat'; cat "$CG_PATH/io.stat" 2>/dev/null || true
  } >"$EVIDENCE/${label}_resource_snapshot.txt"
}

run_sampler() {
  local label=$1 stop_file=$2
  python3 - "$CG_PATH" "$A_EVENT_LOG" "$EVIDENCE/${label}_phase_cpu.jsonl" "$stop_file" <<'PY' &
import json, pathlib, sys, time
cg, events, output, stop = map(pathlib.Path, sys.argv[1:])
def values(path):
    result = {}
    try:
        for line in path.read_text().splitlines():
            parts = line.split()
            if len(parts) == 2:
                try: result[parts[0]] = int(parts[1])
                except ValueError: pass
    except OSError: pass
    return result
def io_full():
    try:
        for line in (cg / "io.pressure").read_text().splitlines():
            if line.startswith("full "):
                for field in line.split():
                    if field.startswith("total="): return int(field.split("=", 1)[1])
    except OSError: pass
    return 0
with output.open("a") as handle:
    while not stop.exists():
        state = {}
        try:
            rows = [json.loads(line) for line in events.read_text().splitlines() if line.strip()]
            state = rows[-1] if rows else {}
        except Exception: pass
        handle.write(json.dumps({
            "time": time.time(), "phase": state.get("phase", "absent"),
            "generation": int(state.get("generation", 0)),
            "cpu_stat": values(cg / "cpu.stat"), "io_full_total": io_full(),
        }, sort_keys=True) + "\n")
        handle.flush(); time.sleep(0.05)
PY
}

reset_b_output() {
  rm -rf "$B_OUTPUT_REAL"
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 755 "$B_OUTPUT_REAL"
}

run_b_trial() {
  local label=$1 deadline_ms=$2
  local stop_file="$LIVE/${label}.stop" before_n before_u after_n after_u rc sampler_pid
  rm -f "$stop_file"
  reset_b_output
  before_n=$(stat_value nr_throttled)
  before_u=$(stat_value throttled_usec)
  run_sampler "$label" "$stop_file"
  sampler_pid=$!
  set +e
  setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
    "$B_PROGRAM" --job "$B_JOB" --output "$B_OUTPUT_REAL" --deadline-ms "$deadline_ms" \
    >"$EVIDENCE/${label}.stdout" 2>"$EVIDENCE/${label}.stderr"
  rc=$?
  set -e
  touch "$stop_file"
  wait "$sampler_pid" 2>/dev/null || true
  after_n=$(stat_value nr_throttled)
  after_u=$(stat_value throttled_usec)
  printf 'rc=%s\nnr_throttled_delta=%s\nthrottled_usec_delta=%s\n' \
    "$rc" "$((after_n-before_n))" "$((after_u-before_u))" >"$EVIDENCE/${label}_cgroup_delta.txt"
  [ ! -s "$B_OUTPUT_REAL/$B_RESULT_NAME" ] || cp "$B_OUTPUT_REAL/$B_RESULT_NAME" "$EVIDENCE/${label}_result.json"
  printf '%s\n' "$rc" >"$EVIDENCE/${label}.rc"
}

wait_a_ready() {
  for attempt in $(seq 1 "$A_READY_ATTEMPTS"); do
    if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/a_ready_${attempt}.txt" 2>&1; then return 0; fi
    sleep "$A_READY_DELAY_SECONDS"
  done
  return 1
}

LAST_COMPUTE_GENERATION=0
wait_new_compute() {
  local generation phase
  for _ in $(seq 1 120); do
    read -r generation phase < <(python3 - "$A_EVENT_LOG" <<'PY' 2>/dev/null || true
import json, pathlib, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
print(rows[-1].get("generation", 0), rows[-1].get("phase", "") if rows else "")
PY
)
    if [ "$phase" = compute ] && [ "$generation" -gt "$LAST_COMPUTE_GENERATION" ]; then
      LAST_COMPUTE_GENERATION=$generation
      return 0
    fi
    sleep 0.05
  done
  return 1
}

threshold_ms=$(python3 - "$RESULT_ROOT/evidence/job_contract.json" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["threshold_ms"])
PY
)
python3 - "$B_JOB" "$threshold_ms" <<'PY' >"$EVIDENCE/task_contract.txt"
import json, pathlib, sys
job = json.loads(pathlib.Path(sys.argv[1]).read_text())
threshold = float(sys.argv[2])
assert threshold > 0
assert threshold in (float(job.get("max_report_ms", -1)), float(job.get("max_module_ms", -1)))
print(f"TASK_CONTRACT_OK=1 threshold_ms={threshold} schema={job['schema']}")
PY

pressure_snapshot before_controls
echo "PHASE=b_alone_controls"
bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/stop_before_controls.txt" 2>&1 || true
for trial in $(seq 1 "$ORACLE_BASELINE_TRIALS"); do run_b_trial "baseline_$trial" "$threshold_ms"; done
if ! python3 - "$EVIDENCE" "$ORACLE_BASELINE_TRIALS" <<'PY' >"$EVIDENCE/baseline_analysis.json"; then fail baseline_controls_failed; fi
import json, pathlib, sys
root, count = pathlib.Path(sys.argv[1]), int(sys.argv[2])
rows = [json.loads((root / f"baseline_{i}_result.json").read_text()) for i in range(1, count + 1)]
ok = all(row.get("complete") is True and int(row.get("deadline_misses", -1)) == 0 and float(row["max_latency_ms"]) <= float(row["deadline_ms"]) for row in rows)
print(json.dumps({"ok": ok, "trials": count, "max_latency_ms": max(float(row["max_latency_ms"]) for row in rows), "threshold_ms": rows[0]["deadline_ms"]}, sort_keys=True, indent=2))
raise SystemExit(0 if ok else 1)
PY
B_ALONE_OK=1

echo "PHASE=start_incumbent"
bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt"
A_STARTED=1
wait_a_ready || fail a_ready_timeout
bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt"
A_HEALTHY=1

echo "PHASE=joint_trials"
for trial in $(seq 1 "$ORACLE_JOINT_TRIALS"); do
  wait_new_compute || fail a_new_compute_phase_timeout
  run_b_trial "joint_$trial" "$threshold_ms"
  if ! bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/a_after_joint_$trial.txt" 2>&1; then fail a_unhealthy_during_joint; fi
done

if ! python3 - "$EVIDENCE" "$ORACLE_JOINT_TRIALS" "$ORACLE_MIN_JOINT_MISSES" "$ORACLE_MIN_THROTTLED_DELTA" "$ORACLE_MIN_CYCLES" "$ORACLE_IO_WAIT_MAX_US" <<'PY' >"$EVIDENCE/joint_analysis.json"; then fail joint_phase_correlation_failed; fi
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1]); count, min_misses, min_throttled, min_cycles, io_max = map(int, sys.argv[2:])
misses = 0; cgroup_throttled = 0; compute_samples = 0; quiet_samples = 0; generations = set(); compute_throttle = 0; quiet_throttle = 0; io_delta = 0
for idx in range(1, count + 1):
    result = json.loads((root / f"joint_{idx}_result.json").read_text())
    misses += int(result.get("deadline_misses", 0))
    text = (root / f"joint_{idx}_cgroup_delta.txt").read_text()
    cgroup_throttled += int(re.search(r"nr_throttled_delta=(\d+)", text).group(1))
    samples = [json.loads(line) for line in (root / f"joint_{idx}_phase_cpu.jsonl").read_text().splitlines() if line.strip()]
    for before, after in zip(samples, samples[1:]):
        delta = max(0, int(after["cpu_stat"].get("nr_throttled", 0)) - int(before["cpu_stat"].get("nr_throttled", 0)))
        if after.get("phase") == "compute": compute_samples += 1; compute_throttle += delta
        else: quiet_samples += 1; quiet_throttle += delta
        if int(after.get("generation", 0)) > 0: generations.add(int(after["generation"]))
        io_delta += max(0, int(after.get("io_full_total", 0)) - int(before.get("io_full_total", 0)))
ok = (misses >= min_misses and cgroup_throttled >= min_throttled and compute_throttle >= min_throttled and compute_throttle > quiet_throttle and compute_samples > 0 and len(generations) >= min_cycles and io_delta <= io_max)
print(json.dumps({"ok": ok, "deadline_misses": misses, "nr_throttled_delta": cgroup_throttled, "compute_phase_throttled_periods": compute_throttle, "quiet_phase_throttled_periods": quiet_throttle, "compute_samples": compute_samples, "quiet_samples": quiet_samples, "generations": sorted(generations), "io_full_pressure_delta_us": io_delta}, sort_keys=True, indent=2))
raise SystemExit(0 if ok else 1)
PY
B_WITH_A_BLOCKED=1

if ! python3 - "$A_TRUST_PATH" "$A_OUTPUT_FILE" "$A_PROGRESS_FIELD" <<'PY' >"$EVIDENCE/a_progress.json"; then fail a_did_not_progress; fi
import json, pathlib, sys
trust = json.loads(pathlib.Path(sys.argv[1]).read_text()); current = json.loads(pathlib.Path(sys.argv[2]).read_text()); field = sys.argv[3]
generation_delta = int(current["generation"]) - int(trust["output"]["generation"])
progress_delta = int(current[field]) - int(trust["output"][field])
ok = generation_delta >= 1 and progress_delta > 0
print(json.dumps({"ok": ok, "generation_delta": generation_delta, "progress_field": field, "progress_delta": progress_delta}, sort_keys=True, indent=2))
raise SystemExit(0 if ok else 1)
PY

echo "PHASE=recovery"
bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a.txt" 2>&1 || true
A_STARTED=0
sleep 0.15
for trial in $(seq 1 "$ORACLE_RECOVERY_TRIALS"); do run_b_trial "recovery_$trial" "$threshold_ms"; done
if ! python3 - "$EVIDENCE" "$ORACLE_RECOVERY_TRIALS" <<'PY' >"$EVIDENCE/recovery_analysis.json"; then fail recovery_failed; fi
import json, pathlib, sys
root, count = pathlib.Path(sys.argv[1]), int(sys.argv[2])
rows = [json.loads((root / f"recovery_{i}_result.json").read_text()) for i in range(1, count + 1)]
misses = sum(int(row.get("deadline_misses", 0)) for row in rows)
max_latency = max(float(row["max_latency_ms"]) for row in rows)
threshold = float(rows[0]["deadline_ms"])
ok = misses == 0 and max_latency <= threshold
print(json.dumps({"ok": ok, "trials": count, "deadline_misses": misses, "max_latency_ms": max_latency, "threshold_ms": threshold}, sort_keys=True, indent=2))
raise SystemExit(0 if ok else 1)
PY
pressure_snapshot after_recovery

summary=$(python3 - "$EVIDENCE/baseline_analysis.json" "$EVIDENCE/joint_analysis.json" "$EVIDENCE/recovery_analysis.json" <<'PY'
import json, pathlib, sys
base, joint, recovery = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]]
print(f"threshold_ms={base['threshold_ms']} baseline_max_ms={base['max_latency_ms']} joint_misses={joint['deadline_misses']} joint_throttled={joint['nr_throttled_delta']} compute_throttled={joint['compute_phase_throttled_periods']} cycles={len(joint['generations'])} io_full_delta_us={joint['io_full_pressure_delta_us']} recovery_max_ms={recovery['max_latency_ms']}")
PY
)
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=cpu_capacity REASON=$ORACLE_REASON $summary"
