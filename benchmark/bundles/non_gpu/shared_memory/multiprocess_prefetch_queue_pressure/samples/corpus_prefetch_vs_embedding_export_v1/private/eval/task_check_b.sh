#!/usr/bin/env bash
set -uo pipefail

ROOT=${PREFETCH_ROOT:?PREFETCH_ROOT must point to the private fixture}
. "$ROOT/fixture.env"
observation=${RESULT_ROOT:?RESULT_ROOT must be set}/evidence/b_runtime_observation.json

runtime_detail=
semantic_detail=
if runtime_detail=$(python3 "$ROOT/eval/verify_b_runtime.py" \
     --observation "$observation" \
     --expected-script "$ROOT/data/run_embedding_export.py" \
     --workers "$B_WORKERS" \
     --prefetch-factor "$B_PREFETCH_FACTOR" \
     --batch-size "$B_BATCH_SIZE" \
     --required-items "$B_REQUIRED_ITEMS" \
     --tensor-ratio "$B_TENSOR_RATIO" \
     --namespace "$B_NAMESPACE" 2>&1) && \
   semantic_detail=$(python3 "$ROOT/eval/verify_b.py" \
     --input /work/input/code_search_corpus.jsonl \
     --output-dir /work/output \
     --workers "$B_WORKERS" \
     --prefetch-factor "$B_PREFETCH_FACTOR" \
     --batch-size "$B_BATCH_SIZE" \
     --required-items "$B_REQUIRED_ITEMS" \
     --tensor-ratio "$B_TENSOR_RATIO" 2>&1); then
  printf '%s\n%s\n' "$runtime_detail" "$semantic_detail"
  echo "TASK_OK=1 semantic_output=1 fixed_recipe=1 root_observed_shared_prefetch=1 items=$B_REQUIRED_ITEMS"
  exit 0
fi

echo "TASK_OK=0 semantic_output=0 fixed_recipe=0 root_observed_shared_prefetch=0 reason=verification_failed"
exit 1
