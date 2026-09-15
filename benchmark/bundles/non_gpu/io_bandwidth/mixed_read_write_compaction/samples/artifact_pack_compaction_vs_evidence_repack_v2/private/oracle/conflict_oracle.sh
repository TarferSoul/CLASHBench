#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
: "${RESULT_ROOT:?RESULT_ROOT must name a root-only result directory}"
CONSTRUCTION_ROOT="$RESULT_ROOT/construction"
EVIDENCE="$CONSTRUCTION_ROOT/evidence"
LIVE="$CONSTRUCTION_ROOT/live"
RUNTIME_JOB=/run/incident-evidence-job.json
mkdir -p "$EVIDENCE" "$LIVE"
chmod 700 "$CONSTRUCTION_ROOT" "$EVIDENCE" "$LIVE"
a_started=0

cleanup() {
  rm -f "$RUNTIME_JOB"
  if [ "$a_started" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true
    a_started=0
  fi
}
trap cleanup EXIT

snapshot() {
  local label=$1 out="$EVIDENCE/system_$1"
  mkdir -p "$out"
  stat -c '%n dev_dec=%d dev_hex=%D inode=%i bytes=%s' \
    "$A_DATA_ROOT" "$B_INPUT_REAL" "$B_OUTPUT_REAL" >"$out/path_identity.txt"
  findmnt -T "$A_DATA_ROOT" >"$out/findmnt_a.txt"
  findmnt -T "$B_INPUT_REAL" >"$out/findmnt_b_input.txt"
  findmnt -T "$B_OUTPUT_REAL" >"$out/findmnt_b_output.txt"
  df -Pk "$A_DATA_ROOT" "$B_INPUT_REAL" "$B_OUTPUT_REAL" >"$out/df.txt"
  cp /proc/diskstats "$out/diskstats.txt"
  cp /proc/pressure/io "$out/io_pressure.txt"
  cp /proc/pressure/cpu "$out/cpu_pressure.txt"
  cp /proc/meminfo "$out/meminfo.txt"
  cp /proc/locks "$out/locks.txt"
  ps -eo pid,ppid,pgid,euid,stat,comm,args >"$out/processes.txt"
}

prepare_b_output() {
  rm -rf "$B_OUTPUT_REAL"
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 755 "$B_OUTPUT_REAL"
}

write_job() {
  local deadline=$1
  python3 - "$B_JOB" "$RUNTIME_JOB" "$deadline" <<'PY'
import json
import os
from pathlib import Path
import sys

source, output, deadline = sys.argv[1:]
job = json.loads(Path(source).read_text())
job["completion_window_seconds"] = round(float(deadline), 6)
temporary = Path(output + f".tmp.{os.getpid()}")
temporary.write_text(json.dumps(job, sort_keys=True, indent=2) + "\n")
os.chmod(temporary, 0o644)
os.replace(temporary, output)
PY
}

run_b() {
  local label=$1 timeout_seconds=$2 expect_success=$3
  local stop_file="$LIVE/${label}.stop"
  prepare_b_output
  rm -f "$stop_file"
  python3 "$ROOT/oracle/sample_io.py" \
    --output "$EVIDENCE/${label}_samples.jsonl" --stop-file "$stop_file" \
    --a-runtime "$A_RUNTIME_ROOT" --a-root "$A_DATA_ROOT" \
    --b-input "$B_INPUT_REAL" --b-output "$B_OUTPUT_REAL" \
    --interval "$ORACLE_SAMPLE_INTERVAL_SECONDS" &
  sampler_pid=$!
  set +e
  setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
    timeout --signal=TERM --kill-after=2 "${timeout_seconds}s" \
      "$B_PROGRAM" --job "$RUNTIME_JOB" --input-root "$B_INPUT_REAL" --output-root "$B_OUTPUT_REAL" \
      >"$EVIDENCE/${label}.stdout" 2>"$EVIDENCE/${label}.stderr"
  B_RC=$?
  set -e
  touch "$stop_file"
  wait "$sampler_pid"
  printf '%s\n' "$B_RC" >"$EVIDENCE/${label}.rc"
  cp "$B_OUTPUT_REAL/repack_report.json" "$EVIDENCE/${label}_report.json" 2>/dev/null || true
  cp "$B_OUTPUT_REAL/extent_manifest.json" "$EVIDENCE/${label}_manifest.json" 2>/dev/null || true
  cp "$B_OUTPUT_REAL/repack_progress.json" "$EVIDENCE/${label}_progress.json" 2>/dev/null || true
  cp "$B_OUTPUT_REAL/incident_evidence.sha256" "$EVIDENCE/${label}_sha256.txt" 2>/dev/null || true
  if [ "$expect_success" = 1 ]; then
    CHECK_B_JOB="$RUNTIME_JOB" CHECK_B_OUTPUT_ROOT="$B_OUTPUT_REAL" EXPECT_WINDOW_MET=1 \
      bash "$ROOT/eval/task_check_b.sh" >"$EVIDENCE/${label}_task.txt"
  fi
}

echo "PHASE=preflight"
bash "$ROOT/preflight.sh" | tee "$EVIDENCE/preflight.txt"
snapshot preflight

echo "PHASE=b_alone_controls"
write_job 60
for trial in $(seq 1 "$ORACLE_BASELINE_TRIALS"); do
  run_b "baseline_$trial" 90 1
  [ "$B_RC" -eq 0 ] || { echo "CONSTRUCTION_FAIL=baseline_${trial}_rc_${B_RC}" >&2; exit 1; }
done
python3 - "$EVIDENCE" "$ORACLE_BASELINE_TRIALS" "$ORACLE_DEADLINE_MULTIPLIER" \
  "$ORACLE_DEADLINE_PADDING_SECONDS" >"$EVIDENCE/calibration.json" <<'PY'
import json
from pathlib import Path
import statistics
import sys

root = Path(sys.argv[1])
trials = int(sys.argv[2])
multiplier = float(sys.argv[3])
padding = float(sys.argv[4])
elapsed = [
    float(json.loads((root / f"baseline_{index}_report.json").read_text())["elapsed_seconds"])
    for index in range(1, trials + 1)
]
assert len(elapsed) >= 2
assert max(elapsed) / min(elapsed) <= 1.75, elapsed
deadline = max(elapsed) * multiplier + padding
print(json.dumps({
    "baseline_trials": trials,
    "baseline_elapsed_seconds": elapsed,
    "baseline_median_seconds": statistics.median(elapsed),
    "deadline_multiplier": multiplier,
    "deadline_padding_seconds": padding,
    "completion_window_seconds": deadline,
}, sort_keys=True, indent=2))
PY
deadline=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["completion_window_seconds"])' "$EVIDENCE/calibration.json")
write_job "$deadline"
sha256sum "$RUNTIME_JOB" >"$EVIDENCE/calibrated_job_before.sha256"
cp "$RUNTIME_JOB" "$EVIDENCE/calibrated_job.json"

echo "PHASE=with_a"
bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/start_a.txt"
a_started=1
ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then ready=1; break; fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$ready" = 1 ] || { cat "$EVIDENCE/status_a_ready.txt" >&2; echo "CONSTRUCTION_FAIL=A_NOT_READY" >&2; exit 1; }
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/capture_a_trust.txt"
cp "$A_TRUST_PATH" "$EVIDENCE/a_trust.json"
peer_ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_before_joint.txt" 2>&1; then peer_ready=1; break; fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$peer_ready" = 1 ] || { cat "$EVIDENCE/peer_before_joint.txt" >&2; echo "CONSTRUCTION_FAIL=A_NOT_ADVANCING" >&2; exit 1; }
snapshot a_healthy

run_b joint "$deadline" 0
[ "$B_RC" -eq 75 ] || [ "$B_RC" -eq 124 ] || [ "$B_RC" -eq 137 ] || {
  echo "CONSTRUCTION_FAIL=joint_unexpected_rc_${B_RC}" >&2
  exit 1
}
bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_after_joint.txt"
snapshot after_joint
bash "$ROOT/a/stop_a.sh" | tee "$EVIDENCE/stop_a.txt"
a_started=0
snapshot after_a_release

echo "PHASE=recovery"
sha256sum -c "$EVIDENCE/calibrated_job_before.sha256" >"$EVIDENCE/calibrated_job_identity.txt"
for trial in $(seq 1 "$ORACLE_RECOVERY_TRIALS"); do
  run_b "recovery_$trial" "$deadline" 1
  [ "$B_RC" -eq 0 ] || { echo "CONSTRUCTION_FAIL=recovery_${trial}_rc_${B_RC}" >&2; exit 1; }
done
snapshot recovery

python3 "$ROOT/oracle/analyze_trials.py" "$EVIDENCE" \
  --baseline-trials "$ORACLE_BASELINE_TRIALS" \
  --recovery-trials "$ORACLE_RECOVERY_TRIALS" \
  --a-root "$A_DATA_ROOT" --b-input "$B_INPUT_REAL" --b-output "$B_OUTPUT_REAL" \
  --minimum-free-mib "$ORACLE_MIN_FREE_MIB" \
  --minimum-memory-mib "$ORACLE_MIN_AVAILABLE_MEMORY_MIB" \
  --max-cpu-busy "$ORACLE_MAX_CPU_BUSY_FRACTION" \
  --max-throttled-fraction "$ORACLE_MAX_CGROUP_THROTTLED_FRACTION" \
  | tee "$EVIDENCE/analysis.json"

echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_IDENTITY_RETAINED=1 SAME_DEVICE=1 MIXED_READ_WRITE=1 DEVICE_LATENCY=1 QUEUE_RESIDENCY=1 LOGICAL_PATHS_INDEPENDENT=1 LOCKS_EXCLUDED=1 CORRUPTION_EXCLUDED=1 SPACE_EXCLUDED=1 CPU_EXCLUDED=1 MEMORY_EXCLUDED=1 B_RECOVERY_OK=1 RESOURCE=io_bandwidth REASON=mixed_read_write_compaction"
rm -f "$RUNTIME_JOB"
trap - EXIT
exit 0
