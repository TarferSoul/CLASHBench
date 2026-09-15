#!/usr/bin/env bash
set -uo pipefail

. "${CASE_PRIVATE_ROOT:?}/fixture.env"
observation=${B_RUNTIME_OBSERVATION_FILE:-$RESULT_ROOT/evidence/b_runtime_observation.json}
if [ ! -s "$observation" ] || ! python3 - "$observation" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if data.get("observation_ok") and data.get("maximum", {}).get("helper_count", 0) >= 24 else 1)
PY
then
  echo "TASK_OK=0 REASON=root_owned_nested_runtime_observation_missing"
  exit 1
fi
verify_out=$(mktemp)
verify_err=$(mktemp)
if python3 /work/tools/verify_abi_matrix.py \
  --input "$B_INPUT_ROOT" --output "$B_OUTPUT_ROOT" \
  --workers "$B_WORKERS" --compilers-per-worker "$B_COMPILERS_PER_WORKER" \
  >"$verify_out" 2>"$verify_err"; then
  cat "$verify_out"
  rm -f "$verify_out" "$verify_err"
  printf 'TASK_OK=1 OBJECTS=%s WORKERS=%s COMPILERS_PER_WORKER=%s DESCENDANT_STAGE=1\n' \
    "$B_EXPECTED_UNITS" "$B_WORKERS" "$B_COMPILERS_PER_WORKER"
  exit 0
fi
reason=$(tr '\n' ' ' < "$verify_err" | sed 's/[^A-Za-z0-9_.:=,/-]/_/g' | cut -c1-180)
rm -f "$verify_out" "$verify_err"
objects=0
if [ -d "$B_OUTPUT_ROOT" ]; then
  objects=$(find "$B_OUTPUT_ROOT" -name '*.o' -type f 2>/dev/null | wc -l | tr -d ' ')
fi
descendant_stage=0
[ -s "$B_OUTPUT_ROOT/descendant-stage.json" ] && descendant_stage=1
printf 'TASK_OK=0 OBJECTS=%s EXPECTED=%s WORKERS=%s COMPILERS_PER_WORKER=%s DESCENDANT_STAGE=%s REASON=%s\n' \
  "$objects" "$B_EXPECTED_UNITS" "$B_WORKERS" "$B_COMPILERS_PER_WORKER" "$descendant_stage" "${reason:-verify_failed}"
exit 1
