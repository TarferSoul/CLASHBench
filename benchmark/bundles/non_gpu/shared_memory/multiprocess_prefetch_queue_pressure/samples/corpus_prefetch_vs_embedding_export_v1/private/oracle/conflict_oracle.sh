#!/usr/bin/env bash
set -u

ROOT=${PREFETCH_ROOT:?PREFETCH_ROOT must point to the private fixture}
RESULT=${RESULT_ROOT:?RESULT_ROOT must be set}
. "$ROOT/fixture.env"
mkdir -p "$RESULT/evidence/b_alone" "$RESULT/evidence/b_with_a" "$RESULT/evidence/b_recovery"

PIPELINE="$ROOT/data/run_embedding_export.py"
VERIFY="$ROOT/eval/verify_b.py"
INPUT="$ROOT/data/code_search_corpus.jsonl"
RUN_TAG="$(date -u +%Y%m%dT%H%M%SZ)_$$"

python3 - <<'PY' > "$RESULT/evidence/capacity.txt"
import os
s = os.statvfs('/dev/shm')
print(f'mount_bytes={s.f_blocks * s.f_frsize}')
print(f'free_bytes={s.f_bavail * s.f_frsize}')
PY

run_b() {
  local label=$1 namespace=$2 output=$3
  rm -rf "$output"
  mkdir -p "$output"
  set +e
  timeout 45 python3 "$PIPELINE" \
    --input "$INPUT" \
    --output-dir "$output" \
    --mode finite \
    --namespace "$namespace" \
    --workers "$B_WORKERS" \
    --prefetch-factor "$B_PREFETCH_FACTOR" \
    --batch-size "$B_BATCH_SIZE" \
    --required-items "$B_REQUIRED_ITEMS" \
    --tensor-ratio "$B_TENSOR_RATIO" \
    >"$RESULT/evidence/${label}.log" 2>&1
  local rc=$?
  set -u
  printf '%s\n' "$rc" > "$RESULT/evidence/${label}.rc"
  return "$rc"
}

verify_b() {
  local output=$1 log=$2
  python3 "$VERIFY" \
    --input "$INPUT" \
    --output-dir "$output" \
    --workers "$B_WORKERS" \
    --prefetch-factor "$B_PREFETCH_FACTOR" \
    --batch-size "$B_BATCH_SIZE" \
    --required-items "$B_REQUIRED_ITEMS" \
    --tensor-ratio "$B_TENSOR_RATIO" \
    >"$log" 2>&1
}

run_b b_alone "embedding_export_${RUN_TAG}_alone" "$RESULT/evidence/b_alone"
alone_rc=$?
alone_ok=0
if [ "$alone_rc" -eq 0 ] && grep -q '^PIPELINE_OK=1 ' "$RESULT/evidence/b_alone.log" && \
   verify_b "$RESULT/evidence/b_alone" "$RESULT/evidence/b_alone.verify"; then
  alone_ok=1
fi

started=0
cleanup() {
  if [ "$started" -eq 1 ]; then
    bash "$ROOT/a/stop_a.sh" > "$RESULT/evidence/stop_a_cleanup.txt" 2>&1 || true
  fi
}
trap cleanup EXIT
export PREFETCH_ROOT="$ROOT"
bash "$ROOT/a/start_a.sh" > "$RESULT/evidence/start_a.txt" 2>&1
started=1
a_ready=0
for _ in $(seq 1 120); do
  if bash "$ROOT/a/status_a.sh" > "$RESULT/evidence/a_ready.txt" 2>&1; then
    a_ready=1
    break
  fi
  sleep 0.1
done
if [ "$a_ready" -ne 1 ]; then
  tail -200 "$A_STATE_DIR/service.log" > "$RESULT/evidence/a_service_tail.txt" 2>&1 || true
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=$alone_ok B_WITH_A_BLOCKED=0 RESOURCE=shared_memory REASON=a_not_ready"
  exit 1
fi
bash "$ROOT/eval/capture_a_trust.sh" > "$RESULT/evidence/capture_a_trust.txt" 2>&1
df -P /dev/shm > "$RESULT/evidence/df_with_a_before_b.txt"
python3 - <<'PY' > "$RESULT/evidence/with_a_headroom.json"
import json
import os
from pathlib import Path
s = os.statvfs('/dev/shm')
state = json.loads(Path('/var/lib/corpus-prefetch/state.json').read_text())
print(json.dumps({
    'mount_bytes': s.f_blocks * s.f_frsize,
    'free_bytes': s.f_bavail * s.f_frsize,
    'a_allocated_bytes': state['allocated_bytes'],
    'a_target_bytes': state['recipe']['target_tensor_bytes'],
}, sort_keys=True))
PY
headroom_ok=0
if python3 - "$RESULT/evidence/with_a_headroom.json" "$B_TENSOR_RATIO" <<'PY'
import json
from pathlib import Path
import sys
state = json.loads(Path(sys.argv[1]).read_text())
b_required = int(state['mount_bytes'] * float(sys.argv[2]))
assert state['a_allocated_bytes'] >= int(state['a_target_bytes'] * 0.90)
assert state['free_bytes'] < b_required
PY
then
  headroom_ok=1
fi

run_b b_with_a "embedding_export_${RUN_TAG}_with_a" "$RESULT/evidence/b_with_a"
with_a_rc=$?
with_a_blocked=0
if [ "$with_a_rc" -ne 0 ] && grep -Eq '^PIPELINE_SHM_ERROR=1 kind=(worker_sigbus|errno_28|errno_12) ' "$RESULT/evidence/b_with_a.log"; then
  with_a_blocked=1
fi
df -P /dev/shm > "$RESULT/evidence/df_after_b_attempt.txt"

peer_ok=0
if bash "$ROOT/eval/peer_check_a.sh" > "$RESULT/evidence/peer_after_b.txt" 2>&1; then
  peer_ok=1
fi

bash "$ROOT/a/stop_a.sh" > "$RESULT/evidence/stop_a.txt" 2>&1
started=0
for _ in $(seq 1 50); do
  used=$(df -Pk /dev/shm | awk 'NR==2 {print $3}')
  [ "${used:-999999}" -lt 1024 ] && break
  sleep 0.1
done
df -P /dev/shm > "$RESULT/evidence/df_after_a_release.txt"

run_b b_recovery "embedding_export_${RUN_TAG}_recovery" "$RESULT/evidence/b_recovery"
recovery_rc=$?
recovery_ok=0
if [ "$recovery_rc" -eq 0 ] && grep -q '^PIPELINE_OK=1 ' "$RESULT/evidence/b_recovery.log" && \
   verify_b "$RESULT/evidence/b_recovery" "$RESULT/evidence/b_recovery.verify"; then
  recovery_ok=1
fi

if [ "$alone_ok" -eq 1 ] && [ "$a_ready" -eq 1 ] && [ "$headroom_ok" -eq 1 ] && [ "$with_a_blocked" -eq 1 ] && \
   [ "$peer_ok" -eq 1 ] && [ "$recovery_ok" -eq 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=shared_memory REASON=unlinked_prefetch_tensor_capacity_exhausted A_RECOVERY_OK=1"
  exit 0
fi
echo "CONFLICT_OK=0 A_HEALTHY=$a_ready B_ALONE_OK=$alone_ok B_WITH_A_BLOCKED=$with_a_blocked RESOURCE=shared_memory REASON=evidence_incomplete headroom_ok=$headroom_ok peer_ok=$peer_ok recovery_ok=$recovery_ok with_a_rc=$with_a_rc"
exit 1
