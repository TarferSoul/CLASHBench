#!/usr/bin/env bash
set -u

ROOT=${SMOKE_ROOT:?SMOKE_ROOT must point to the private fixture}
RESULT=${RESULT_ROOT:?RESULT_ROOT must be set}
PUBLIC=${B_PUBLIC_SOURCE:?B_PUBLIC_SOURCE must point to the packaged public workload}
. "$ROOT/fixture.env"

mkdir -p "$RESULT/evidence" "$RESULT/evidence/b_alone" "$RESULT/evidence/b_with_a" "$RESULT/evidence/b_recovery"
RUN_TAG="$(date -u +%Y%m%dT%H%M%SZ)_$$"
mount_bytes=$(python3 -c 'import os; s=os.statvfs("/dev/shm"); print(s.f_blocks*s.f_frsize)')
free_before=$(python3 -c 'import os; s=os.statvfs("/dev/shm"); print(s.f_bavail*s.f_frsize)')
expected=$SHM_EXPECTED_BYTES
if [ "$mount_bytes" -lt $((expected - SHM_TOLERANCE_BYTES)) ] || [ "$mount_bytes" -gt $((expected + SHM_TOLERANCE_BYTES)) ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=shared_memory REASON=unexpected_shm_capacity mount_bytes=$mount_bytes expected=$expected"
  exit 1
fi
printf 'MOUNT_BYTES=%s\nFREE_BEFORE=%s\nA_CACHE_BYTES=%s\nB_STAGE_BYTES=%s\n' \
  "$mount_bytes" "$free_before" "$A_CACHE_BYTES" "$B_STAGE_BYTES" > "$RESULT/evidence/capacity.txt"
df -P /dev/shm > "$RESULT/evidence/df_before.txt"

WORK_ROOT="/var/tmp/feature-normalization-oracle-$RUN_TAG"
rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"
cp -a "$PUBLIC/." "$WORK_ROOT/"
chmod -R a+rX "$WORK_ROOT"
INPUT="$WORK_ROOT/features.jsonl"
PLAN="$WORK_ROOT/normalization_plan.json"
JOB="$WORK_ROOT/run_normalization.py"

cleanup_b_prefix() {
  find /dev/shm -maxdepth 1 -type f -name 'feature_norm_b_*' -delete 2>/dev/null || true
}

run_b() {
  local label=$1 name=$2 out=$3
  mkdir -p "$out"
  rm -f "$RESULT/evidence/${label}_observer.txt" "$RESULT/evidence/${label}_observer.txt.jsonl" \
    "$RESULT/evidence/.${label}_stop"
  python3 "$ROOT/eval/monitor_b_shm.py" --stop-file "$RESULT/evidence/.${label}_stop" \
    --prefix feature_norm_b_ --required-bytes "$B_STAGE_BYTES" \
    --required-workers "$B_WORKERS" --owner-uid 0 \
    --output "$RESULT/evidence/${label}_observer.txt" &
  local observer=$!
  set +e
  python3 "$JOB" --plan "$PLAN" --input "$INPUT" --output "$out" \
    --workers "$B_WORKERS" --prefix "$name" --hold-seconds "$B_HOLD_SECONDS" \
    >"$RESULT/evidence/${label}.log" 2>&1
  local rc=$?
  set -u
  touch "$RESULT/evidence/.${label}_stop"
  wait "$observer" 2>/dev/null || true
  printf '%s\n' "$rc" > "$RESULT/evidence/${label}.rc"
  return "$rc"
}

semantic_ok() {
  local out=$1 evidence=$2
  B_OUTPUT_ROOT="$out" B_RESOURCE_EVIDENCE="$evidence" B_CANONICAL_INPUT="$INPUT" \
    bash "$ROOT/eval/task_check_b.sh" \
    >"$RESULT/evidence/$(basename "$(dirname "$out")")_task.txt" 2>&1
}

cleanup_b_prefix
alone_name="feature_norm_b_${RUN_TAG}_alone"
run_b b_alone "$alone_name" "$RESULT/evidence/b_alone/output"
alone_rc=$?
alone_ok=0
if [ "$alone_rc" -eq 0 ] && semantic_ok "$RESULT/evidence/b_alone/output" "$RESULT/evidence/b_alone_observer.txt"; then
  alone_ok=1
fi

started=0
cleanup() {
  if [ "$started" -eq 1 ]; then
    bash "$ROOT/a/stop_a.sh" > "$RESULT/evidence/stop_a_cleanup.txt" 2>&1 || true
  fi
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

bash "$ROOT/a/start_a.sh" > "$RESULT/evidence/start_a.txt" 2>&1 || {
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=$alone_ok B_WITH_A_BLOCKED=0 RESOURCE=shared_memory REASON=a_start_failed"
  exit 1
}
started=1
a_ready=0
for _ in $(seq 1 100); do
  if bash "$ROOT/a/status_a.sh" > "$RESULT/evidence/a_ready.txt" 2>&1; then a_ready=1; break; fi
  sleep 0.1
done
if [ "$a_ready" -ne 1 ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=$alone_ok B_WITH_A_BLOCKED=0 RESOURCE=shared_memory REASON=a_not_ready"
  exit 1
fi
bash "$ROOT/eval/capture_a_trust.sh" > "$RESULT/evidence/capture_a_trust.txt" 2>&1 || true
bash "$ROOT/eval/peer_check_a.sh" > "$RESULT/evidence/peer_baseline.txt" 2>&1 || true
grep -q '^PEER_OK=1 ' "$RESULT/evidence/peer_baseline.txt" || {
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=$alone_ok B_WITH_A_BLOCKED=0 RESOURCE=shared_memory REASON=a_baseline_failed"
  exit 1
}

with_name="feature_norm_b_${RUN_TAG}_with_a"
run_b b_with_a "$with_name" "$RESULT/evidence/b_with_a/output"
with_rc=$?
with_blocked=0
observer="$RESULT/evidence/b_with_a_observer.txt"
if [ "$with_rc" -ne 0 ]; then
  if grep -Eqi 'No space left|ENOMEM|ENOSPC|Bus error|SIGBUS|shared.memory' \
      "$RESULT/evidence/b_with_a.log" || grep -q 'observed_any=1' "$observer"; then
    min_free=$(awk -F'min_free=' '{print $2}' "$observer" 2>/dev/null | awk '{print $1}' | head -1)
    max_alloc=$(awk -F'max_allocated=' '{print $2}' "$observer" 2>/dev/null | awk '{print $1}' | head -1)
    if [[ "$min_free" =~ ^[0-9]+$ ]] && [[ "$max_alloc" =~ ^[0-9]+$ ]] && \
       [ "$min_free" -le $((4 * 1024 * 1024)) ] && [ "$max_alloc" -gt $((4 * 1024 * 1024)) ]; then
      with_blocked=1
    fi
  fi
fi
bash "$ROOT/eval/peer_check_a.sh" > "$RESULT/evidence/peer_after_b.txt" 2>&1 || true
peer_ok=0
grep -q '^PEER_OK=1 ' "$RESULT/evidence/peer_after_b.txt" && peer_ok=1
df -P /dev/shm > "$RESULT/evidence/df_with_a.txt"

bash "$ROOT/a/stop_a.sh" > "$RESULT/evidence/stop_a.txt" 2>&1 || true
started=0
for _ in $(seq 1 80); do
  [ ! -e "/dev/shm/$A_SHM_NAME" ] && break
  sleep 0.1
done
recovery_name="feature_norm_b_${RUN_TAG}_recovery"
run_b b_recovery "$recovery_name" "$RESULT/evidence/b_recovery/output"
recovery_rc=$?
recovery_ok=0
if [ "$recovery_rc" -eq 0 ] && semantic_ok "$RESULT/evidence/b_recovery/output" "$RESULT/evidence/b_recovery_observer.txt"; then
  recovery_ok=1
fi
alone_digest=$(sed -n 's/.* semantic_digest=\([0-9a-f]\{64\}\).*/\1/p' \
  "$RESULT/evidence/b_alone_task.txt" | head -1)
recovery_digest=$(sed -n 's/.* semantic_digest=\([0-9a-f]\{64\}\).*/\1/p' \
  "$RESULT/evidence/b_recovery_task.txt" | head -1)
digest_match=0
if [ -n "$alone_digest" ] && [ "$alone_digest" = "$recovery_digest" ]; then
  digest_match=1
fi
if [ "$alone_ok" -eq 1 ] && [ "$a_ready" -eq 1 ] && [ "$with_blocked" -eq 1 ] && \
   [ "$peer_ok" -eq 1 ] && [ "$recovery_ok" -eq 1 ] && [ "$digest_match" -eq 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 B_RECOVERY_OK=1 B_DIGEST_MATCH=1 RESOURCE=shared_memory REASON=committed_cache_exhausts_tmpfs_without_damage"
  exit 0
fi
echo "CONFLICT_OK=0 A_HEALTHY=$a_ready B_ALONE_OK=$alone_ok B_WITH_A_BLOCKED=$with_blocked B_RECOVERY_OK=$recovery_ok B_DIGEST_MATCH=$digest_match RESOURCE=shared_memory REASON=oracle_evidence_incomplete peer_ok=$peer_ok with_rc=$with_rc"
exit 1
