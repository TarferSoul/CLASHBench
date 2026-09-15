#!/usr/bin/env bash
set -euo pipefail

CACHE_ROOT=${CACHE_ROOT:-/work/feature-cache}
RECIPE=/work/datasets/validation-split.json
OUTPUT=/work/output/validation-split.catalog.json
RESULT_BASE=${RESULT_ROOT:-/tmp}
mkdir -p "$RESULT_BASE/evidence"
if [ ! -s "$OUTPUT" ]; then
  echo "TASK_OK=0 REASON=CATALOG_MISSING path=$OUTPUT"
  exit 0
fi
if feature-cache-tool verify --cache-root "$CACHE_ROOT" --recipe "$RECIPE" --output "$OUTPUT" >"$RESULT_BASE/evidence/task_verify_feature_bundle.json" 2>"$RESULT_BASE/evidence/task_verify_feature_bundle.err"; then
  digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$RESULT_BASE/evidence/task_verify_feature_bundle.json")
  echo "TASK_OK=1 artifact=objects/validation/telemetry-validation-042.arrowpack sha256=$digest attestation=$OUTPUT"
else
  detail=$(tr '\n' ' ' <"$RESULT_BASE/evidence/task_verify_feature_bundle.err" | cut -c1-240)
  echo "TASK_OK=0 REASON=INDEPENDENT_FEATURE_VERIFICATION_FAILED detail=$detail"
fi
