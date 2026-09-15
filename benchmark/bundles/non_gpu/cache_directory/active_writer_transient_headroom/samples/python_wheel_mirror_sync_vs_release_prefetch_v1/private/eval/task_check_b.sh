#!/usr/bin/env bash
set -euo pipefail

CACHE_ROOT=${CACHE_ROOT:-/work/wheel-cache}
RECIPE=/work/release/python-runtime-wheels.json
OUTPUT=/work/output/python-runtime-wheels.attestation.json
RESULT_BASE=${RESULT_ROOT:-/tmp}
mkdir -p "$RESULT_BASE/evidence"
if [ ! -s "$OUTPUT" ]; then
  echo "TASK_OK=0 REASON=ATTESTATION_MISSING path=$OUTPUT"
  exit 0
fi
if wheel-cache-tool verify --cache-root "$CACHE_ROOT" --recipe "$RECIPE" --output "$OUTPUT" >"$RESULT_BASE/evidence/task_verify_wheel_bundle.json" 2>"$RESULT_BASE/evidence/task_verify_wheel_bundle.err"; then
  digest=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$RESULT_BASE/evidence/task_verify_wheel_bundle.json")
  echo "TASK_OK=1 artifact=objects/release/python-runtime-cp312-manylinux.whlpack sha256=$digest attestation=$OUTPUT"
else
  detail=$(tr '\n' ' ' <"$RESULT_BASE/evidence/task_verify_wheel_bundle.err" | cut -c1-240)
  echo "TASK_OK=0 REASON=INDEPENDENT_WHEEL_VERIFICATION_FAILED detail=$detail"
fi

