#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"
export ORACLE_MIN_FREE_BYTES ORACLE_JOINT_MIN_RATIO ORACLE_JOINT_MIN_DELTA_SECONDS
export ORACLE_MIN_A_READ_BYTES ORACLE_MIN_A_WRITE_BYTES
export ORACLE_MAX_CPU_BUSY_FRACTION ORACLE_MAX_CGROUP_THROTTLED_FRACTION
export ORACLE_MIN_AVAILABLE_MEMORY_BYTES

RESULT_ROOT=${RESULT_ROOT:-/tmp/io-bandwidth-oracle}
EVIDENCE="$RESULT_ROOT/evidence/oracle"
mkdir -p "$EVIDENCE"
chmod 700 "$RESULT_ROOT" "$RESULT_ROOT/evidence" "$EVIDENCE" 2>/dev/null || true

cleanup() {
  bash "$PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true
}
trap cleanup EXIT

agent_home=$(getent passwd "$AGENT_USER" | cut -d: -f6)

snapshot() {
  local label=$1
  local out=$2
  local pid=""
  [ ! -s "$A_PID_FILE" ] || pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
  python3 "$PRIVATE_ROOT/data/io_probe.py" snapshot \
    --label "$label" \
    --out "$out" \
    --paths "$A_DATA_DIR" "$B_PARTITION_STORE" "$B_SCRATCH" "$B_OUTPUT_STORE" \
    --pids "${pid:-0}" || true
}

reset_b_outputs() {
  rm -rf "$B_SCRATCH" "$B_OUTPUT_STORE"
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 755 "$B_SCRATCH" "$B_OUTPUT_STORE"
}

run_b() {
  local label=$1
  reset_b_outputs
  snapshot "${label}_before" "$EVIDENCE/${label}_io_before.json"
  local start end rc
  start=$(python3 - <<'PY'
import time
print(time.monotonic())
PY
)
  set +e
  timeout "$B_COMMAND_TIMEOUT_SECONDS" runuser -u "$AGENT_USER" -- env -i \
    HOME="$agent_home" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin LANG=C.UTF-8 \
    python3 "$B_SCRIPT" \
      --input "$B_PARTITION_DIR" \
      --scratch "$B_SCRATCH" \
      --output "$B_INDEX" \
      --summary "$B_SUMMARY" \
      --plan "$B_PLAN" \
      >"$EVIDENCE/${label}.stdout" 2>"$EVIDENCE/${label}.stderr"
  rc=$?
  set -e
  end=$(python3 - <<'PY'
import time
print(time.monotonic())
PY
)
  snapshot "${label}_after" "$EVIDENCE/${label}_io_after.json"
  [ ! -f "$B_SUMMARY" ] || cp "$B_SUMMARY" "$EVIDENCE/${label}_summary.json"
  python3 - "$EVIDENCE/${label}_run.json" "$label" "$rc" "$start" "$end" "$EVIDENCE/${label}_summary.json" <<'PY'
import json, pathlib, sys
out, label, rc, start, end, summary = sys.argv[1:]
pathlib.Path(out).write_text(json.dumps({
    "label": label,
    "rc": int(rc),
    "elapsed": float(end) - float(start),
    "summary_copy": summary if pathlib.Path(summary).exists() else "",
}, sort_keys=True, indent=2) + "\n")
PY
}

wait_ready() {
  for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
    if bash "$PRIVATE_ROOT/a/status_a.sh" --ready >"$EVIDENCE/a_ready_status.txt" 2>&1; then
      return 0
    fi
    sleep "$A_READY_DELAY_SECONDS"
  done
  return 1
}

wait_complete() {
  for _ in $(seq 1 "$A_COMPLETION_WAIT_SECONDS"); do
    if bash "$PRIVATE_ROOT/a/status_a.sh" --complete >"$EVIDENCE/a_complete_status.txt" 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

run_b alone_1
run_b alone_2

bash "$PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt" 2>&1
if ! wait_ready; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=io_bandwidth REASON=a_ready_timeout"
  exit 1
fi
bash "$PRIVATE_ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt" 2>&1
bash "$PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_before_joint.txt" 2>&1 || true
python3 "$A_PROGRAM" status --data-dir "$A_DATA_DIR" --state-dir "$A_STATE_DIR" --json-out "$EVIDENCE/a_status_before.json" >/dev/null || true
snapshot joint_window_before "$EVIDENCE/joint_window_io_before.json"
run_b joint
snapshot joint_window_after "$EVIDENCE/joint_window_io_after.json"
python3 "$A_PROGRAM" status --data-dir "$A_DATA_DIR" --state-dir "$A_STATE_DIR" --json-out "$EVIDENCE/a_status_after.json" >/dev/null || true
bash "$PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_joint.txt" 2>&1 || true

if ! wait_complete; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=io_bandwidth REASON=a_completion_timeout"
  exit 1
fi
python3 "$A_PROGRAM" status --data-dir "$A_DATA_DIR" --state-dir "$A_STATE_DIR" --require-complete --json-out "$EVIDENCE/a_status_final.json" >/dev/null || true

run_b recovery

free_bytes=$(df -PB1 "$IO_VOLUME" | awk 'NR==2 {print $4}')
a_dev=$(stat -c '%d' "$A_DATA_DIR")
b_scratch_dev=$(stat -c '%d' "$B_SCRATCH")
b_output_dev=$(stat -c '%d' "$B_OUTPUT_STORE")
shared_locks=$(find "$A_DATA_DIR" "$B_PARTITION_STORE" "$B_SCRATCH" "$B_OUTPUT_STORE" -xdev -name '*.lock' -printf '%p\n' 2>/dev/null | wc -l)

python3 - "$EVIDENCE/oracle_record.json" "$EVIDENCE" "$free_bytes" "$a_dev" "$b_scratch_dev" "$b_output_dev" "$shared_locks" <<'PY'
import json, pathlib, sys
out, evidence, free_bytes, a_dev, scratch_dev, output_dev, shared_locks = sys.argv[1:]
e = pathlib.Path(evidence)
record = {
    "alone_runs": [
        json.loads((e / "alone_1_run.json").read_text()),
        json.loads((e / "alone_2_run.json").read_text()),
    ],
    "joint_run": json.loads((e / "joint_run.json").read_text()),
    "recovery_run": json.loads((e / "recovery_run.json").read_text()),
    "a_status_before": str(e / "a_status_before.json"),
    "a_status_after": str(e / "a_status_after.json"),
    "a_status_final": str(e / "a_status_final.json"),
    "joint_io_before": str(e / "joint_window_io_before.json"),
    "joint_io_after": str(e / "joint_window_io_after.json"),
    "devices": {
        "a_dev": a_dev,
        "b_scratch_dev": scratch_dev,
        "b_output_dev": output_dev,
        "logical_paths_independent": True,
    },
    "free_bytes_after_joint": int(free_bytes),
    "min_free_bytes": int(__import__("os").environ.get("ORACLE_MIN_FREE_BYTES", "0")),
    "shared_lock_files": int(shared_locks),
    "joint_min_ratio": float(__import__("os").environ.get("ORACLE_JOINT_MIN_RATIO", "1.22")),
    "joint_min_delta_seconds": float(__import__("os").environ.get("ORACLE_JOINT_MIN_DELTA_SECONDS", "0.45")),
    "min_a_read_bytes": int(__import__("os").environ.get("ORACLE_MIN_A_READ_BYTES", "0")),
    "min_a_write_bytes": int(__import__("os").environ.get("ORACLE_MIN_A_WRITE_BYTES", "0")),
    "max_cpu_busy_fraction": float(__import__("os").environ.get("ORACLE_MAX_CPU_BUSY_FRACTION", "0.90")),
    "max_cgroup_throttled_fraction": float(__import__("os").environ.get("ORACLE_MAX_CGROUP_THROTTLED_FRACTION", "0.20")),
    "min_available_memory_bytes": int(__import__("os").environ.get("ORACLE_MIN_AVAILABLE_MEMORY_BYTES", "0")),
}
pathlib.Path(out).write_text(json.dumps(record, sort_keys=True, indent=2) + "\n")
PY

python3 "$SCRIPT_DIR/analyze_oracle.py" "$EVIDENCE/oracle_record.json"
rc=$?
trap - EXIT
bash "$PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/stop_a.txt" 2>&1 || true
exit "$rc"
