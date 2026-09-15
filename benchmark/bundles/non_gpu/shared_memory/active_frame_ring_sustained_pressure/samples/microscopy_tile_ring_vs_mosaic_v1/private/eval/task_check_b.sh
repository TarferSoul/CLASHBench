#!/usr/bin/env bash
set -uo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

runtime_ok=0
semantic_ok=0
if grep -q '^B_RUNTIME_OK=1 ' "$RESULT_ROOT/evidence/b_runtime_observation.txt" 2>/dev/null; then
  runtime_ok=1
fi
if python3 "$ROOT/data/verify_mosaic.py" \
  --output "$B_OUTPUT" --items "$B_ITEMS" --workers "$B_WORKERS" \
  >"$RESULT_ROOT/evidence/b_semantic_verification.txt" 2>&1; then
  semantic_ok=1
fi
ok=$((runtime_ok * semantic_ok))
printf 'TASK_OK=%s B_RUNTIME_OBSERVED=%s SEMANTIC_OUTPUT_OK=%s output=%s\n' \
  "$ok" "$runtime_ok" "$semantic_ok" "$B_OUTPUT"
exit $((1 - ok))
