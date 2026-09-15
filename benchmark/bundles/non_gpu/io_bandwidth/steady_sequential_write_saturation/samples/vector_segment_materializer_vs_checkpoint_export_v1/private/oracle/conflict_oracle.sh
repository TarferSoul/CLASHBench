#!/bin/bash
set -Eeuo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
RESULT_ROOT=${RESULT_ROOT:-/tmp/io-bandwidth-oracle}
ORACLE_ROOT="$RESULT_ROOT/construction"
EVIDENCE="$ORACLE_ROOT/evidence"
LIVE="$ORACLE_ROOT/live"
mkdir -p "$EVIDENCE" "$LIVE"
chmod 700 "$ORACLE_ROOT" "$EVIDENCE" "$LIVE"
started=0

cleanup() {
  if [ "$started" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a_cleanup.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

run_b() {
  local label=$1
  local stop_file="$LIVE/${label}.stop"
  rm -f "$stop_file"
  rm -rf "$B_OUTPUT_ROOT"
  install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 755 "$B_OUTPUT_ROOT"
  python3 "$ROOT/oracle/io_probe.py" --output "$EVIDENCE/${label}_samples.jsonl" \
    --stop-file "$stop_file" --a-runtime "$A_RUNTIME_ROOT" --interval "$B_SAMPLE_INTERVAL_SECONDS" &
  local sampler_pid=$!
  set +e
  setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --init-groups \
    env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" PATH="$PATH" \
    "$B_TOOL" --source "$B_SOURCE_FILE" --expected-sha256-file "$B_EXPECTED_FILE" --output "$B_OUTPUT_ROOT" \
    >"$EVIDENCE/${label}.stdout" 2>"$EVIDENCE/${label}.stderr"
  B_RC=$?
  set -e
  touch "$stop_file"
  wait "$sampler_pid"
  printf '%s\n' "$B_RC" >"$EVIDENCE/${label}.rc"
  cp "$B_OUTPUT_ROOT/checkpoint-export.json" "$EVIDENCE/${label}_report.json" 2>/dev/null || true
  CHECK_B_OUTPUT_ROOT="$B_OUTPUT_ROOT" bash "$ROOT/eval/task_check_b.sh" >"$EVIDENCE/${label}_task.txt" 2>&1 || true
}

echo "PHASE=preflight"
bash "$ROOT/preflight.sh" | tee "$EVIDENCE/preflight.txt"

echo "PHASE=b_alone_controls"
for trial in $(seq 1 "$B_BASELINE_TRIALS"); do
  run_b "baseline_$trial"
  [ "$B_RC" -eq 0 ] || { echo "CONSTRUCTION_FAIL=baseline_${trial}_rc_${B_RC}" >&2; exit 1; }
  grep -q '^TASK_OK=1 ' "$EVIDENCE/baseline_${trial}_task.txt" || { echo "CONSTRUCTION_FAIL=baseline_${trial}_semantic" >&2; exit 1; }
done
python3 - "$EVIDENCE" "$B_BASELINE_TRIALS" "$B_MIN_JOINT_SLOWDOWN_RATIO" "$B_MAX_BASELINE_SPREAD_RATIO" <<'PY' | tee "$EVIDENCE/calibration.txt"
import json
import math
from pathlib import Path
import sys

root, trials, ratio, spread = Path(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
times = [json.loads((root / f"baseline_{idx}_report.json").read_text())["copy_elapsed_ms"] for idx in range(1, trials + 1)]
assert min(times) > 0 and max(times) / min(times) <= spread, "B-alone controls are not repeatable"
print(f"BASELINE_TRIALS={trials}")
print(f"BASELINE_COPY_MS={','.join(map(str, times))}")
print(f"PREDECLARED_MIN_SLOWDOWN_RATIO={ratio:.3f}")
print(f"FIXED_JOINT_THRESHOLD_MS={math.ceil(max(times) * ratio)}")
PY

echo "PHASE=with_a"
bash "$ROOT/a/start_a.sh" | tee "$EVIDENCE/start_a.txt"
started=1
ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$ready" = 1 ] || { cat "$A_LOG_PATH" >&2 || true; echo "CONSTRUCTION_FAIL=A_NOT_READY" >&2; exit 1; }
bash "$ROOT/eval/capture_a_trust.sh" | tee "$EVIDENCE/capture_a_trust.txt"
cp "$A_TRUST_FILE" "$EVIDENCE/a_trust.json"
peer_ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_before_joint.txt" 2>&1; then
    peer_ready=1
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$peer_ready" = 1 ] || { cat "$EVIDENCE/peer_before_joint.txt" >&2; echo "CONSTRUCTION_FAIL=A_NOT_ADVANCING" >&2; exit 1; }

for trial in $(seq 1 "$B_JOINT_TRIALS"); do
  cp "$A_STATUS_FILE" "$EVIDENCE/a_status_before_joint_${trial}.json"
  run_b "joint_$trial"
  [ "$B_RC" -eq 0 ] || { echo "CONSTRUCTION_FAIL=joint_${trial}_rc_${B_RC}" >&2; exit 1; }
  grep -q '^TASK_OK=1 ' "$EVIDENCE/joint_${trial}_task.txt" || { echo "CONSTRUCTION_FAIL=joint_${trial}_semantic" >&2; exit 1; }
  bash "$ROOT/eval/peer_check_a.sh" | tee "$EVIDENCE/peer_after_joint_${trial}.txt"
done
cp "$A_STATUS_FILE" "$EVIDENCE/a_status_after_joint.json"
cp "$A_OUTPUT_ROOT/segment-ledger.tsv" "$EVIDENCE/a_segment_ledger.tsv"
cp "$A_LOG_PATH" "$EVIDENCE/a_materializer.log"
bash "$ROOT/a/stop_a.sh" | tee "$EVIDENCE/stop_a.txt"
started=0

echo "PHASE=recovery"
for _ in $(seq 1 10); do
  inflight=$(awk '{sum += $12} END {print sum+0}' /proc/diskstats)
  [ "$inflight" -eq 0 ] && break
  sleep 0.10
done
run_b "recovery_1"
[ "$B_RC" -eq 0 ] || { echo "CONSTRUCTION_FAIL=recovery_rc_${B_RC}" >&2; exit 1; }
grep -q '^TASK_OK=1 ' "$EVIDENCE/recovery_1_task.txt" || { echo "CONSTRUCTION_FAIL=recovery_semantic" >&2; exit 1; }

python3 "$ROOT/oracle/analyze_trials.py" "$EVIDENCE" \
  --baseline-trials "$B_BASELINE_TRIALS" --joint-trials "$B_JOINT_TRIALS" \
  --min-slowdown "$B_MIN_JOINT_SLOWDOWN_RATIO" --max-baseline-spread "$B_MAX_BASELINE_SPREAD_RATIO" \
  --max-recovery-ratio "$B_MAX_RECOVERY_RATIO" --min-release-speedup "$B_MIN_RELEASE_SPEEDUP_RATIO" \
  --payload-mib "$PAYLOAD_MIB" --min-a-rate "$A_MIN_WRITE_MIB_PER_SEC" | tee "$EVIDENCE/analysis.txt"

echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 A_IDENTITY_RETAINED=1 SAME_DEVICE=1 WRITE_SECTORS=1 QUEUE_RESIDENCY=1 IO_PRESSURE=1 ALTERNATE_CAUSES_EXCLUDED=1 B_RECOVERY_OK=1 RESOURCE=io_bandwidth REASON=steady_sequential_write_saturation"
trap - EXIT
exit 0

