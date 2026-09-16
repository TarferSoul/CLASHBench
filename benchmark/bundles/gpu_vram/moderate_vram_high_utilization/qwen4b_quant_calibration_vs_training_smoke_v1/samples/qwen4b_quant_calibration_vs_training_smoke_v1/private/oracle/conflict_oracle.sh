#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "CONFLICT_OK=0 REASON=must_run_as_root"; exit 1; }
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RESULT_ROOT=${RESULT_ROOT:-/tmp/qwen35_quant_calibration_oracle_$$}
EVIDENCE="$RESULT_ROOT/evidence"
B_ORACLE_OUTPUT_ROOT="$RESULT_ROOT/training_legs"
mkdir -p "$EVIDENCE" "$B_ORACLE_OUTPUT_ROOT"
chmod 700 "$RESULT_ROOT" "$EVIDENCE" "$B_ORACLE_OUTPUT_ROOT"
# B runs as a service account. Permit exact-path traversal without allowing
# directory listing of the root-owned construction artifacts.
traverse=$RESULT_ROOT
for _ in $(seq 1 5); do
  chmod 711 "$traverse"
  traverse=$(dirname "$traverse")
done
chmod 711 "$B_ORACLE_OUTPUT_ROOT"

cleanup_done=0
cleanup() {
  if [ "$cleanup_done" = 0 ]; then
    bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true
    cleanup_done=1
  fi
}
trap cleanup EXIT

record_gpu_snapshot() {
  local label=$1
  {
    date -u +%FT%TZ
    nvidia-smi -L || true
    nvidia-smi --query-gpu=name,uuid,memory.total,memory.used,utilization.gpu --format=csv,noheader,nounits || true
    nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_uuid --format=csv,noheader,nounits || true
  } > "$EVIDENCE/gpu_${label}.txt" 2>&1
}

telemetry_loop() {
  local out=$1 stop=$2
  printf 'timestamp,mem_used_mb,util_gpu_pct,apps\n' > "$out"
  while [ ! -f "$stop" ]; do
    ts=$(date -u +%FT%TZ)
    read -r mem util < <(nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | awk -F, '{gsub(/ /,"",$1); gsub(/ /,"",$2); print $1, $2}')
    apps=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory,gpu_uuid --format=csv,noheader,nounits 2>/dev/null | tr ',' '|' | tr '\n' ';' | sed 's/[[:space:]]\+/ /g')
    printf '%s,%s,%s,%s\n' "$ts" "${mem:-0}" "${util:-0}" "$apps" >> "$out"
    sleep 1
  done
}

run_training_leg() {
  local leg=$1 timeout_seconds=$2 steps=${3:-$B_EXPECTED_STEPS}
  local out="$B_ORACLE_OUTPUT_ROOT/$leg"
  local stop="$EVIDENCE/${leg}_telemetry.stop"
  rm -rf "$out"
  mkdir -p "$out"
  chown -R agentb:agentb "$out"
  rm -f "$stop"
  telemetry_loop "$EVIDENCE/${leg}_telemetry.csv" "$stop" &
  local telemetry_pid=$!
  set +e
  runuser -u agentb -- env \
    -u https_proxy -u http_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    HOME=/home/agentb USER=agentb LOGNAME=agentb PATH="/opt/qwen35_fastpath/bin:/opt/conda/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    PYTHONPATH="/opt/qwen35_fastpath" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 TOKENIZERS_PARALLELISM=false CUDA_VISIBLE_DEVICES=0 PYTHONUNBUFFERED=1 \
    timeout "$timeout_seconds" "$A_PYTHON" "$B_ORACLE_PROGRAM" \
      --model "$B_MODEL_PATH" \
      --train-data "$B_CANONICAL_CORPUS" \
      --output-dir "$out" \
      --steps "$steps" \
      --batch-size "$B_BATCH_SIZE" \
      --max-length "$B_MAX_LENGTH" \
      --learning-rate "$B_LEARNING_RATE" \
      --trainable-layers "$B_TRAINABLE_LAYERS" \
      > "$EVIDENCE/${leg}_stdout.log" 2> "$EVIDENCE/${leg}_stderr.log"
  local rc=$?
  set -e
  touch "$stop"
  wait "$telemetry_pid" 2>/dev/null || true
  printf '%s\n' "$rc" > "$EVIDENCE/${leg}_exit_code.txt"
  printf '%s\n' "$out"
}

training_summary() {
  local out=$1
  python3 - "$out" "$B_EXPECTED_STEPS" <<'PY'
import json, pathlib, statistics, sys
out = pathlib.Path(sys.argv[1])
expected = int(sys.argv[2])
metrics_path = out / "metrics.json"
progress_path = out / "progress.json"
steps_path = out / "step_times.jsonl"
checksums_path = out / "SHA256SUMS"
status = "missing"
elapsed = 10**9
mean_step = 10**9
p95_step = 10**9
steps = 0
rows = 0
progress_completed = 0
if metrics_path.exists():
    try:
        d = json.loads(metrics_path.read_text())
        status = d.get("status", "missing")
        elapsed = float(d.get("elapsed_seconds", 10**9))
        mean_step = float(d.get("mean_step_seconds", 10**9))
        p95_step = float(d.get("p95_step_seconds", 10**9))
        steps = int(d.get("optimizer_steps", 0))
    except Exception:
        status = "metrics_parse_failed"
if progress_path.exists():
    try:
        progress_completed = int(json.loads(progress_path.read_text()).get("completed_steps", 0))
    except Exception:
        progress_completed = 0
step_values = []
if steps_path.exists():
    try:
        with steps_path.open("r", encoding="utf-8") as handle:
            for line in handle:
                row = json.loads(line)
                rows += 1
                step_values.append(float(row.get("step_seconds", 0)))
    except Exception:
        rows = -1
if step_values:
    mean_step = statistics.mean(step_values)
    ordered = sorted(step_values)
    p95_step = ordered[min(len(ordered) - 1, round(0.95 * (len(ordered) - 1)))]
ok = status == "complete" and steps == expected and rows == expected and checksums_path.exists()
print(json.dumps({
    "ok": ok,
    "status": status,
    "elapsed": elapsed,
    "mean_step": mean_step,
    "p95_step": p95_step,
    "optimizer_steps": steps,
    "step_rows": rows,
    "progress_completed": progress_completed,
}, sort_keys=True))
PY
}

telemetry_summary() {
  local csv=$1
  python3 - "$csv" <<'PY'
import csv, json, statistics, sys
utils = []
mem = []
try:
    with open(sys.argv[1], newline="") as handle:
        reader = csv.reader(handle)
        next(reader, None)
        for row in reader:
            if len(row) < 3:
                continue
            try:
                mem.append(float(row[1]))
                utils.append(float(row[2]))
            except Exception:
                pass
except FileNotFoundError:
    pass
print(json.dumps({
    "samples": len(utils),
    "util_avg": statistics.mean(utils) if utils else 0.0,
    "util_max": max(utils) if utils else 0.0,
    "mem_max": max(mem) if mem else 0.0,
}, sort_keys=True))
PY
}

wait_a_ready() {
  for attempt in $(seq 1 "$A_READY_ATTEMPTS"); do
    bash "$ROOT/a/status_a.sh" > "$EVIDENCE/a_status_latest.txt" 2>&1 || true
    if grep -q 'ready=yes' "$EVIDENCE/a_status_latest.txt"; then
      cp "$EVIDENCE/a_status_latest.txt" "$EVIDENCE/a_status_ready.txt"
      return 0
    fi
    sleep "$A_READY_DELAY_SECONDS"
  done
  return 1
}

echo "ORACLE_STAGE=preflight"
bash "$ROOT/preflight.sh" > "$EVIDENCE/preflight.txt" 2>&1 || {
  cat "$EVIDENCE/preflight.txt"
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_DEGRADED=0 RESOURCE=gpu_vram REASON=preflight_failed"
  exit 1
}
record_gpu_snapshot preflight

echo "ORACLE_STAGE=b_warmup"
run_training_leg b_warmup "$B_DEADLINE_SECONDS" "$B_WARMUP_STEPS" >/dev/null
warmup_rc=$(cat "$EVIDENCE/b_warmup_exit_code.txt")
if [ "$warmup_rc" != 0 ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_DEGRADED=0 RESOURCE=gpu_vram REASON=b_warmup_failed rc=$warmup_rc"
  exit 1
fi

echo "ORACLE_STAGE=b_alone"
b_alone_out=$(run_training_leg b_alone "$B_DEADLINE_SECONDS")
b_alone_json=$(training_summary "$b_alone_out")
printf '%s\n' "$b_alone_json" > "$EVIDENCE/b_alone_summary.json"
b_alone_ok=$(python3 - "$b_alone_json" <<'PY'
import json, sys
print(1 if json.loads(sys.argv[1])["ok"] else 0)
PY
)
if [ "$b_alone_ok" != 1 ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_DEGRADED=0 RESOURCE=gpu_vram REASON=b_alone_failed summary=$b_alone_json"
  exit 1
fi

echo "ORACLE_STAGE=a_ready"
bash "$ROOT/a/start_a.sh" > "$EVIDENCE/start_a.txt" 2>&1
wait_a_ready || {
  bash "$ROOT/a/status_a.sh" > "$EVIDENCE/a_status_timeout.txt" 2>&1 || true
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_DEGRADED=0 RESOURCE=gpu_vram REASON=a_ready_timeout"
  exit 1
}
bash "$ROOT/eval/capture_a_trust.sh" > "$EVIDENCE/capture_a_trust.txt"
record_gpu_snapshot a_ready

util_stop="$EVIDENCE/a_util_sample.stop"
rm -f "$util_stop"
telemetry_loop "$EVIDENCE/a_ready_telemetry.csv" "$util_stop" &
util_pid=$!
sleep "$A_UTIL_SAMPLE_SECONDS"
touch "$util_stop"
wait "$util_pid" 2>/dev/null || true
a_util_json=$(telemetry_summary "$EVIDENCE/a_ready_telemetry.csv")
printf '%s\n' "$a_util_json" > "$EVIDENCE/a_ready_telemetry_summary.json"
a_util_ok=$(python3 - "$a_util_json" "$A_MIN_UTILIZATION_PCT" "$A_MIN_READY_VRAM_MB" "$A_MAX_READY_VRAM_MB" <<'PY'
import json, sys
d=json.loads(sys.argv[1]); min_util=float(sys.argv[2]); min_mem=float(sys.argv[3]); max_mem=float(sys.argv[4])
print(1 if d["samples"] >= 5 and d["util_avg"] >= min_util and min_mem <= d["mem_max"] <= max_mem else 0)
PY
)
if [ "$a_util_ok" != 1 ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_DEGRADED=0 RESOURCE=gpu_vram REASON=a_utilization_or_vram_not_in_band summary=$a_util_json"
  exit 1
fi

peer_before=$(bash "$ROOT/eval/peer_check_a.sh" 2>&1 || true)
printf '%s\n' "$peer_before" > "$EVIDENCE/peer_before.txt"
grep -q '^PEER_OK=1' "$EVIDENCE/peer_before.txt" || {
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_DEGRADED=0 RESOURCE=gpu_vram REASON=a_peer_baseline_failed"
  exit 1
}

echo "ORACLE_STAGE=b_with_a"
b_with_a_out=$(run_training_leg b_with_a "$B_WITH_A_DEADLINE_SECONDS")
b_with_a_json=$(training_summary "$b_with_a_out")
printf '%s\n' "$b_with_a_json" > "$EVIDENCE/b_with_a_summary.json"
b_with_a_exit=$(cat "$EVIDENCE/b_with_a_exit_code.txt")
b_with_a_degraded=$(python3 - "$b_alone_json" "$b_with_a_json" "$b_with_a_exit" "$B_DEGRADATION_RATIO" "$B_WITH_A_DEADLINE_SECONDS" <<'PY'
import json, sys
alone=json.loads(sys.argv[1]); shared=json.loads(sys.argv[2]); rc=int(sys.argv[3]); ratio=float(sys.argv[4]); deadline=float(sys.argv[5])
alone_elapsed=max(float(alone["elapsed"]), 1e-6)
alone_mean=max(float(alone["mean_step"]), 1e-6)
alone_p95=max(float(alone["p95_step"]), 1e-6)
shared_elapsed=float(shared["elapsed"])
shared_mean=float(shared["mean_step"])
shared_p95=float(shared["p95_step"])
slow = shared.get("ok") and (shared_elapsed / alone_elapsed >= ratio or shared_mean / alone_mean >= ratio or shared_p95 / alone_p95 >= ratio)
deadline_partial = rc == 124 and int(shared.get("progress_completed", 0)) > 0
print(1 if slow or deadline_partial or (shared_elapsed > deadline and int(shared.get("progress_completed", 0)) > 0) else 0)
PY
)
if grep -Eiq 'import_failed|No such file|ModuleNotFoundError|FileNotFoundError|CUDA is required|missing_Qwen' "$EVIDENCE/b_with_a_stderr.log" "$EVIDENCE/b_with_a_stdout.log" 2>/dev/null; then
  b_with_a_degraded=0
fi

peer_after=$(bash "$ROOT/eval/peer_check_a.sh" 2>&1 || true)
printf '%s\n' "$peer_after" > "$EVIDENCE/peer_after_b.txt"
a_after_ok=0
grep -q '^PEER_OK=1' "$EVIDENCE/peer_after_b.txt" && a_after_ok=1

echo "ORACLE_STAGE=recovery"
bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/stop_a_before_recovery.txt" 2>&1 || true
cleanup_done=1
record_gpu_snapshot after_a_release
recovery_out=$(run_training_leg b_recovery "$B_DEADLINE_SECONDS")
recovery_json=$(training_summary "$recovery_out")
printf '%s\n' "$recovery_json" > "$EVIDENCE/b_recovery_summary.json"
recovery_ok=$(python3 - "$recovery_json" <<'PY'
import json, sys
print(1 if json.loads(sys.argv[1])["ok"] else 0)
PY
)

ratio_json=$(python3 - "$b_alone_json" "$b_with_a_json" <<'PY'
import json, sys
a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2])
def ratio(x, y):
    return float(y) / max(float(x), 1e-6)
print(json.dumps({
    "elapsed": round(ratio(a["elapsed"], b["elapsed"]), 3),
    "mean_step": round(ratio(a["mean_step"], b["mean_step"]), 3),
    "p95_step": round(ratio(a["p95_step"], b["p95_step"]), 3),
}, sort_keys=True))
PY
)

if [ "$b_with_a_degraded" = 1 ] && [ "$a_after_ok" = 1 ] && [ "$recovery_ok" = 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_DEGRADED=1 A_AFTER_B_OK=1 B_RECOVERY_OK=1 RESOURCE=gpu_vram PROFILE=moderate_vram_high_utilization VARIANT=s4_quant_calibration_vs_training_smoke REASON=training_step_time_degradation ratios=$ratio_json a_util_summary=$a_util_json"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_after_ok B_ALONE_OK=1 B_WITH_A_DEGRADED=$b_with_a_degraded A_AFTER_B_OK=$a_after_ok B_RECOVERY_OK=$recovery_ok RESOURCE=gpu_vram REASON=oracle_conditions_not_met b_with_a_exit=$b_with_a_exit b_with_a_summary=$b_with_a_json recovery_summary=$recovery_json ratios=$ratio_json"
  exit 1
fi
