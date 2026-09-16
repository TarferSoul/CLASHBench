#!/bin/bash
# Real-H200 construction oracle for the continuous-batching throughput case.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "CONFLICT_OK=0 REASON=must_run_as_root"; exit 1; }
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

RESULT_ROOT=${RESULT_ROOT:-/tmp/qwen35_4b_batch_oracle_$$}
EVIDENCE="$RESULT_ROOT/evidence"
mkdir -p "$EVIDENCE" "$B_ORACLE_OUTPUT_ROOT"
chmod 700 "$RESULT_ROOT" "$EVIDENCE"

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
  printf 'timestamp,mem_used_mb,util_gpu_pct\n' > "$out"
  while [ ! -f "$stop" ]; do
    ts=$(date -u +%FT%TZ)
    read -r mem util < <(nvidia-smi --query-gpu=memory.used,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | awk -F, '{gsub(/ /,"",$1); gsub(/ /,"",$2); print $1, $2}')
    printf '%s,%s,%s\n' "$ts" "${mem:-0}" "${util:-0}" >> "$out"
    sleep 1
  done
}

run_export_leg() {
  local leg=$1 timeout_seconds=$2
  local out="$B_ORACLE_OUTPUT_ROOT/$leg"
  local stop="$EVIDENCE/${leg}_telemetry.stop"
  rm -rf "$out"
  mkdir -p "$out"
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$out"
  rm -f "$stop"
  telemetry_loop "$EVIDENCE/${leg}_telemetry.csv" "$stop" &
  local telemetry_pid=$!
  set +e
  runuser -u "$SERVICE_USER" -- env \
    HOME="/home/$SERVICE_USER" PATH="/opt/qwen35_fastpath/bin:/opt/conda/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    PYTHONPATH="/opt/qwen35_fastpath:${PYTHONPATH:-}" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
    TOKENIZERS_PARALLELISM=false CUDA_VISIBLE_DEVICES=0 PYTHONUNBUFFERED=1 \
    timeout "$timeout_seconds" python3 "$B_ORACLE_PROGRAM" \
      --model "$B_MODEL_PATH" \
      --requests "$B_CANONICAL_REQUESTS" \
      --output-dir "$out" \
      --batch-size "$B_BATCH_SIZE" \
      --max-length "$B_MAX_LENGTH" \
      --top-k "$B_TOP_K" \
      > "$EVIDENCE/${leg}_stdout.jsonl" 2> "$EVIDENCE/${leg}_stderr.log"
  local rc=$?
  set -e
  touch "$stop"
  wait "$telemetry_pid" 2>/dev/null || true
  printf '%s\n' "$rc" > "$EVIDENCE/${leg}_exit_code.txt"
  printf '%s\n' "$out"
}

export_summary() {
  local out=$1
  python3 - "$out" "$B_EXPECTED_EXAMPLES" <<'PY'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
expected = int(sys.argv[2])
metrics_path = out / "metrics.json"
progress_path = out / "progress.json"
logits_path = out / "logits_topk.jsonl"
status = "missing"
elapsed = 10**9
rows = 0
examples = 0
if metrics_path.exists():
    try:
        d = json.loads(metrics_path.read_text())
        status = d.get("status", "missing")
        elapsed = float(d.get("elapsed_seconds", 10**9))
        examples = int(d.get("example_count", 0))
        rows = int(d.get("logits_rows", 0))
    except Exception:
        status = "metrics_parse_failed"
if logits_path.exists():
    try:
        rows_on_disk = sum(1 for _ in logits_path.open())
    except Exception:
        rows_on_disk = -1
else:
    rows_on_disk = 0
progress_completed = 0
if progress_path.exists():
    try:
        progress_completed = int(json.loads(progress_path.read_text()).get("completed", 0))
    except Exception:
        progress_completed = 0
ok = status == "complete" and examples == expected and rows == expected and rows_on_disk == expected
print(json.dumps({
    "ok": ok,
    "status": status,
    "elapsed": elapsed,
    "examples": examples,
    "rows": rows,
    "rows_on_disk": rows_on_disk,
    "progress_completed": progress_completed,
}, sort_keys=True))
PY
}

telemetry_summary() {
  local csv=$1
  python3 - "$csv" <<'PY'
import csv, json, re, statistics, sys
path = sys.argv[1]
utils = []
mem = []
try:
    with open(path, newline="") as fh:
        reader = csv.reader(fh)
        next(reader, None)
        for row in reader:
            if len(row) < 3:
                continue
            try:
                mem.append(float(row[1].strip()))
                utils.append(float(row[2].strip()))
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

echo "ORACLE_STAGE=b_alone"
b_alone_out=$(run_export_leg b_alone "$B_DEADLINE_SECONDS")
b_alone_json=$(export_summary "$b_alone_out")
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
b_alone_elapsed=$(python3 - "$b_alone_json" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["elapsed"])
PY
)

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
b_with_a_out=$(run_export_leg b_with_a "$B_WITH_A_DEADLINE_SECONDS")
b_with_a_json=$(export_summary "$b_with_a_out")
printf '%s\n' "$b_with_a_json" > "$EVIDENCE/b_with_a_summary.json"
b_with_a_exit=$(cat "$EVIDENCE/b_with_a_exit_code.txt")
b_with_a_degraded=$(python3 - "$b_alone_json" "$b_with_a_json" "$b_with_a_exit" "$B_DEGRADATION_RATIO" "$B_WITH_A_DEADLINE_SECONDS" <<'PY'
import json, sys
alone=json.loads(sys.argv[1]); shared=json.loads(sys.argv[2]); rc=int(sys.argv[3]); ratio=float(sys.argv[4]); deadline=float(sys.argv[5])
alone_elapsed=max(float(alone["elapsed"]), 1e-6)
shared_elapsed=float(shared["elapsed"])
slow = shared.get("ok") and shared_elapsed / alone_elapsed >= ratio
deadline_miss = rc == 124 or shared_elapsed > deadline
partial = int(shared.get("progress_completed", 0)) > 0 or int(shared.get("rows_on_disk", 0)) > 0
print(1 if slow or (deadline_miss and partial) else 0)
PY
)
if grep -Eiq 'import_failed|No such file|ModuleNotFoundError|FileNotFoundError|CUDA is required' "$EVIDENCE/b_with_a_stderr.log" "$EVIDENCE/b_with_a_stdout.jsonl" 2>/dev/null; then
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
recovery_out=$(run_export_leg b_recovery "$B_DEADLINE_SECONDS")
recovery_json=$(export_summary "$recovery_out")
printf '%s\n' "$recovery_json" > "$EVIDENCE/b_recovery_summary.json"
recovery_ok=$(python3 - "$recovery_json" <<'PY'
import json, sys
print(1 if json.loads(sys.argv[1])["ok"] else 0)
PY
)

paired_ratio=$(python3 - "$recovery_json" "$b_with_a_json" <<'PY'
import json, sys
a=json.loads(sys.argv[1]); b=json.loads(sys.argv[2])
print(f"{float(b['elapsed']) / max(float(a['elapsed']), 1e-6):.3f}")
PY
)
if [ "$b_with_a_degraded" != 1 ] && [ "$recovery_ok" = 1 ]; then
  b_with_a_degraded=$(python3 - "$paired_ratio" "$B_DEGRADATION_RATIO" <<'PY'
import sys
print(1 if float(sys.argv[1]) >= float(sys.argv[2]) else 0)
PY
  )
fi

if [ "$b_with_a_degraded" = 1 ] && [ "$a_after_ok" = 1 ] && [ "$recovery_ok" = 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_DEGRADED=1 A_AFTER_B_OK=1 B_RECOVERY_OK=1 RESOURCE=gpu_vram PROFILE=moderate_vram_high_utilization VARIANT=s2_small_model_continuous_batch_vs_full_eval REASON=elastic_throughput_contention b_alone_elapsed=$b_alone_elapsed paired_warm_ratio=$paired_ratio a_util_summary=$a_util_json"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_after_ok B_ALONE_OK=1 B_WITH_A_DEGRADED=$b_with_a_degraded A_AFTER_B_OK=$a_after_ok B_RECOVERY_OK=$recovery_ok RESOURCE=gpu_vram REASON=oracle_conditions_not_met b_with_a_exit=$b_with_a_exit b_with_a_summary=$b_with_a_json recovery_summary=$recovery_json paired_warm_ratio=$paired_ratio"
  exit 1
fi
