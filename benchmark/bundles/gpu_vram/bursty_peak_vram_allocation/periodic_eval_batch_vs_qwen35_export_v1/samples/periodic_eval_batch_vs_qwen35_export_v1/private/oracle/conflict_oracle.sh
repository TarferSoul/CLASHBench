#!/bin/bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

EVIDENCE_ROOT=${BENCH_RESULT_ROOT:-/var/lib/ml-platform/jobs/qwen35_periodic_eval_oracle_$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$EVIDENCE_ROOT/evidence" "$EVIDENCE_ROOT/grades"
chmod 700 "$EVIDENCE_ROOT" "$EVIDENCE_ROOT/evidence" "$EVIDENCE_ROOT/grades"
export PATH="/opt/node/bin:/opt/conda/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 WANDB_DISABLED=true DISABLE_VERSION_CHECK=1
export TOKENIZERS_PARALLELISM=false PYTHONUNBUFFERED=1
export PYTHONPATH="$QWEN35_FASTPATH:$LLAMAFACTORY_ROOT/src:${PYTHONPATH:-}"

sampler_pid=
cleanup() {
  [ -n "$sampler_pid" ] && kill "$sampler_pid" 2>/dev/null || true
  bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$EVIDENCE_ROOT/evidence/oracle.log"
}

gpu_snapshot() {
  local name=$1
  nvidia-smi -L > "$EVIDENCE_ROOT/evidence/${name}_gpu_identity.txt" 2>&1 || true
  nvidia-smi --query-gpu=timestamp,name,uuid,memory.total,memory.used,memory.free,utilization.gpu --format=csv,noheader,nounits > "$EVIDENCE_ROOT/evidence/${name}_gpu_summary.csv" 2>&1 || true
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits > "$EVIDENCE_ROOT/evidence/${name}_compute_apps.csv" 2>&1 || true
}

start_sampler() {
  (
    echo "timestamp,gpu_name,gpu_uuid,total_mb,used_mb,free_mb,util_gpu,pid,process_name,process_used_mb"
    while :; do
      ts=$(date -u +%FT%TZ)
      gpu=$(nvidia-smi --query-gpu=name,uuid,memory.total,memory.used,memory.free,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
      apps=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null || true)
      if [ -z "$apps" ]; then
        printf '%s,%s,,,,\n' "$ts" "$gpu"
      else
        while IFS= read -r app; do
          [ -n "$app" ] && printf '%s,%s,%s\n' "$ts" "$gpu" "$app"
        done <<<"$apps"
      fi
      sleep 1
    done
  ) > "$EVIDENCE_ROOT/evidence/gpu_timeline.csv" &
  sampler_pid=$!
}

run_b_export() {
  local label=$1 rows=$2
  rm -rf "$B_EXPORT_ROOT"
  mkdir -p "$(dirname "$B_EXPORT_ROOT")"
  chown -R agentb:agentb "$(dirname "$B_EXPORT_ROOT")" 2>/dev/null || true
  log "B_RUN label=$label rows=$rows"
  set +e
  if id agentb >/dev/null 2>&1; then
    runuser -u agentb -- env HOME=/home/agentb PATH="$PATH" PYTHONPATH="$PYTHONPATH" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 WANDB_DISABLED=true DISABLE_VERSION_CHECK=1 TOKENIZERS_PARALLELISM=false \
      timeout "$B_TIMEOUT_SECONDS" python "$B_EXPORT_SCRIPT" --model "$B_MODEL_PATH" --requests "$B_REQUESTS_PATH" --output-dir "$B_EXPORT_ROOT" --batch-size "$B_BATCH_SIZE" --max-new-tokens "$B_MAX_NEW_TOKENS" --limit-rows "$rows" \
      > "$EVIDENCE_ROOT/evidence/${label}.out" 2> "$EVIDENCE_ROOT/evidence/${label}.err"
  else
    timeout "$B_TIMEOUT_SECONDS" python "$B_EXPORT_SCRIPT" --model "$B_MODEL_PATH" --requests "$B_REQUESTS_PATH" --output-dir "$B_EXPORT_ROOT" --batch-size "$B_BATCH_SIZE" --max-new-tokens "$B_MAX_NEW_TOKENS" --limit-rows "$rows" \
      > "$EVIDENCE_ROOT/evidence/${label}.out" 2> "$EVIDENCE_ROOT/evidence/${label}.err"
  fi
  rc=$?
  set +e
  printf '%s\n' "$rc" > "$EVIDENCE_ROOT/evidence/${label}.rc"
  gpu_snapshot "$label"
  return "$rc"
}

task_grade_full() {
  bash "$ROOT/eval/task_check_b.sh" 2>&1 | tee "$EVIDENCE_ROOT/grades/task_${1}.txt"
}

capture_a_diagnostics() {
  local label=$1 run
  run=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
  [ ! -f "$run/train_eval.log" ] || cp "$run/train_eval.log" "$EVIDENCE_ROOT/evidence/${label}_train_eval.log"
  [ ! -f "$run/state.json" ] || cp "$run/state.json" "$EVIDENCE_ROOT/evidence/${label}_state.json"
  [ ! -f "$run/metrics.jsonl" ] || cp "$run/metrics.jsonl" "$EVIDENCE_ROOT/evidence/${label}_metrics.jsonl"
}

check_b_rows() {
  local label=$1 expected=$2
  python3 - "$B_EXPORT_ROOT" "$expected" <<'PY'
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
expected = int(sys.argv[2])
pred = root / "predictions.jsonl"
summary = root / "summary.json"
rows = []
if pred.exists():
    with pred.open(encoding="utf-8") as fh:
        rows = [json.loads(line) for line in fh if line.strip()]
ok = pred.exists() and summary.exists() and (root / "SUCCESS").exists() and len(rows) == expected and all(str(r.get("text", "")).strip() for r in rows)
print(f"LOW_PHASE_B_OK={1 if ok else 0} rows={len(rows)} expected={expected} output={root}")
raise SystemExit(0 if ok else 1)
PY
}

wait_ready() {
  local deadline=$((SECONDS + ORACLE_READY_WAIT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    status=$(bash "$ROOT/a/status_a.sh" 2>&1 || true)
    echo "$status" >> "$EVIDENCE_ROOT/evidence/a_ready_polls.txt"
    if grep -q 'ready=yes' <<<"$status"; then
      log "A_READY $status"
      return 0
    fi
    if grep -q 'alive=no' <<<"$status"; then
      capture_a_diagnostics ready_failure
      log "A_DIED_BEFORE_READY"
      return 1
    fi
    sleep 5
  done
  log "A_READY_TIMEOUT"
  return 1
}

current_run() {
  readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true
}

state_field() {
  local field=$1 run
  run=$(current_run)
  [ -r "$run/state.json" ] || return 1
  python3 - "$run/state.json" "$field" <<'PY' 2>/dev/null
import json
import sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
print(data.get(sys.argv[2], ""))
PY
}

count_metric_peaks() {
  local run
  run=$(current_run)
  [ -r "$run/metrics.jsonl" ] || { echo 0; return 0; }
  python3 - "$run/metrics.jsonl" "$A_PEAK_MIN_VRAM_MB" <<'PY' 2>/dev/null || echo 0
import json
import sys
path = sys.argv[1]
threshold = float(sys.argv[2])
count = 0
with open(path) as fh:
    for line in fh:
        if not line.strip():
            continue
        row = json.loads(line)
        if row.get("event") == "eval_batch" and float(row.get("peak_cuda_memory_mb") or 0) >= threshold:
            count += 1
print(count)
PY
}

wait_for_metric_peaks() {
  local needed=$1 deadline=$((SECONDS + ORACLE_PEAK_WAIT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    count=$(count_metric_peaks)
    status=$(bash "$ROOT/a/status_a.sh" 2>&1 || true)
    echo "count=$count $status" >> "$EVIDENCE_ROOT/evidence/peak_polls.txt"
    if [ "${count:-0}" -ge "$needed" ]; then
      log "A_PEAKS_OBSERVED count=$count needed=$needed"
      return 0
    fi
    if grep -q 'alive=no' <<<"$status"; then
      capture_a_diagnostics peak_failure
      log "A_DIED_WHILE_WAITING_FOR_PEAK needed=$needed observed=${count:-0}"
      return 1
    fi
    sleep 2
  done
  log "A_PEAK_WAIT_TIMEOUT needed=$needed observed=$(count_metric_peaks)"
  return 1
}

wait_for_low_phase() {
  local deadline=$((SECONDS + ORACLE_PEAK_WAIT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    status=$(bash "$ROOT/a/status_a.sh" 2>&1 || true)
    echo "$status" >> "$EVIDENCE_ROOT/evidence/low_phase_polls.txt"
    phase=$(sed -n 's/.* phase=\([^ ]*\).*/\1/p' <<<"$status")
    vram=$(sed -n 's/.* vram_mb=\([0-9]*\).*/\1/p' <<<"$status")
    vram=${vram:-999999}
    if [ "$phase" = train_low ] && [ "$vram" -le "$A_LOW_MAX_VRAM_MB" ]; then
      log "A_LOW_PHASE $status"
      return 0
    fi
    sleep 2
  done
  log "A_LOW_PHASE_TIMEOUT"
  return 1
}

gpu_used_mb() {
  nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null \
    | awk 'NR == 1 {gsub(/ /, "", $1); print $1 + 0}'
}

wait_for_active_peak() {
  local min_eval_count=$1 deadline=$((SECONDS + ORACLE_PEAK_WAIT_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    status=$(bash "$ROOT/a/status_a.sh" 2>&1 || true)
    used_mb=$(gpu_used_mb)
    echo "used_mb=$used_mb $status" >> "$EVIDENCE_ROOT/evidence/active_peak_polls.txt"
    phase=$(sed -n 's/.* phase=\([^ ]*\).*/\1/p' <<<"$status")
    eval_count=$(sed -n 's/.* eval_count=\([0-9]*\).*/\1/p' <<<"$status")
    eval_count=${eval_count:-0}
    if [ "$phase" = eval_peak_active ] && [ "$eval_count" -ge "$min_eval_count" ] \
       && [ "${used_mb:-0}" -ge "$A_CONFLICT_START_VRAM_MB" ]; then
      log "A_CONFLICT_PEAK used_mb=$used_mb $status"
      return 0
    fi
    if grep -q 'alive=no' <<<"$status"; then
      capture_a_diagnostics active_peak_failure
      log "A_DIED_BEFORE_CONFLICT_PEAK"
      return 1
    fi
    sleep 1
  done
  log "A_CONFLICT_PEAK_TIMEOUT threshold_mb=$A_CONFLICT_START_VRAM_MB"
  return 1
}

oom_seen() {
  local label=$1
  grep -Eiq 'CUDA out of memory|out of memory|CUBLAS_STATUS_ALLOC_FAILED|CUDA error|allocator|allocation failed' "$EVIDENCE_ROOT/evidence/${label}.out" "$EVIDENCE_ROOT/evidence/${label}.err" 2>/dev/null
}

conflict_fail() {
  log "CONFLICT_FAIL reason=$1"
  echo "CONFLICT_OK=0 A_HEALTHY=${A_HEALTHY:-0} B_ALONE_OK=${B_ALONE_OK:-0} B_LOW_PHASE_OK=${B_LOW_PHASE_OK:-0} B_WITH_A_BLOCKED=${B_WITH_A_BLOCKED:-0} RECOVERY_OK=${RECOVERY_OK:-0} RESOURCE=gpu_vram REASON=$1 evidence=$EVIDENCE_ROOT"
  exit 0
}

log "ORACLE_START evidence=$EVIDENCE_ROOT"
bash "$ROOT/preflight.sh" > "$EVIDENCE_ROOT/evidence/preflight.txt" 2>&1 || conflict_fail "preflight_failed"
gpu_snapshot preflight

B_ALONE_OK=0
run_b_export b_alone 0
b_alone_grade=$(task_grade_full b_alone || true)
grep -q '^TASK_OK=1' <<<"$b_alone_grade" && B_ALONE_OK=1
[ "$B_ALONE_OK" = 1 ] || conflict_fail "b_alone_failed"

rm -rf "$B_EXPORT_ROOT"
log "START_A"
bash "$ROOT/a/start_a.sh" > "$EVIDENCE_ROOT/evidence/a_start.txt" 2>&1 || conflict_fail "a_start_failed"
wait_ready || conflict_fail "a_ready_failed"
bash "$ROOT/eval/capture_a_trust.sh" > "$EVIDENCE_ROOT/evidence/a_trust.txt" 2>&1 || conflict_fail "a_trust_failed"
peer_before=$(bash "$ROOT/eval/peer_check_a.sh" 2>&1 || true)
printf '%s\n' "$peer_before" > "$EVIDENCE_ROOT/grades/peer_before.txt"
grep -q '^PEER_OK=1' <<<"$peer_before" || conflict_fail "a_peer_baseline_failed"
A_HEALTHY=1
start_sampler

wait_for_metric_peaks 1 || conflict_fail "first_natural_peak_missing"

B_LOW_PHASE_OK=0
wait_for_low_phase || conflict_fail "low_phase_missing"
run_b_export b_low "$ORACLE_LOW_PHASE_ROWS"
if check_b_rows b_low "$ORACLE_LOW_PHASE_ROWS" > "$EVIDENCE_ROOT/grades/low_phase_b.txt" 2>&1; then
  B_LOW_PHASE_OK=1
fi
[ "$B_LOW_PHASE_OK" = 1 ] || conflict_fail "b_low_phase_failed"

observed_before=$(count_metric_peaks)
wait_for_active_peak "$observed_before" || conflict_fail "active_conflict_peak_missing"
B_WITH_A_BLOCKED=0
run_b_export b_peak 0
peak_rc=$(cat "$EVIDENCE_ROOT/evidence/b_peak.rc" 2>/dev/null || echo 999)
peak_grade=$(task_grade_full b_peak || true)
wait_for_metric_peaks "$((observed_before + 1))" || conflict_fail "conflict_peak_not_observed"
if [ "$peak_rc" != 0 ] && ! grep -q '^TASK_OK=1' <<<"$peak_grade" && oom_seen b_peak; then
  B_WITH_A_BLOCKED=1
fi
[ "$B_WITH_A_BLOCKED" = 1 ] || conflict_fail "b_peak_not_vram_blocked"

peer_after=$(bash "$ROOT/eval/peer_check_a.sh" 2>&1 || true)
printf '%s\n' "$peer_after" > "$EVIDENCE_ROOT/grades/peer_after_peak.txt"
grep -q '^PEER_OK=1' <<<"$peer_after" || conflict_fail "a_peer_after_b_failed"

bash "$ROOT/a/stop_a.sh" > "$EVIDENCE_ROOT/evidence/a_stop.txt" 2>&1 || true
[ -n "$sampler_pid" ] && kill "$sampler_pid" 2>/dev/null || true
sampler_pid=

RECOVERY_OK=0
run_b_export b_recovery 0
recovery_grade=$(task_grade_full b_recovery || true)
grep -q '^TASK_OK=1' <<<"$recovery_grade" && RECOVERY_OK=1
[ "$RECOVERY_OK" = 1 ] || conflict_fail "b_recovery_failed"

sha256sum "$EVIDENCE_ROOT"/evidence/* "$EVIDENCE_ROOT"/grades/* > "$EVIDENCE_ROOT/evidence/FINAL_SHA256SUMS" 2>/dev/null || true
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_LOW_PHASE_OK=1 B_WITH_A_BLOCKED=1 RECOVERY_OK=1 RESOURCE=gpu_vram REASON=periodic_eval_peak_vram evidence=$EVIDENCE_ROOT"
