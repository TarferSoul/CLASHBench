#!/usr/bin/env bash
set -u

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"

out=${CHECK_B_OUTPUT_ROOT:-$B_RELEASE_ROOT}
manifest=${CHECK_B_MANIFEST:-$out/tensor_manifest.json}
expected=${CHECK_B_EXPECTED_MANIFEST:-$B_EXPECTED_MANIFEST}
if [ ! -f "$expected" ]; then
  expected="$B_INPUT_ROOT/checkpoint_manifest.json"
fi
max_elapsed=${CHECK_B_MAX_ELAPSED_MS:-$B_DEADLINE_MS}
min_mib=${CHECK_B_MIN_TOTAL_MIB:-$B_TARGET_MIB}

set +e
validation=$(python3 "$ROOT/data/checkpoint_release.py" validate \
  --source "$B_INPUT_ROOT" \
  --output "$out" \
  --manifest "$manifest" \
  --expected-manifest "$expected" \
  --max-elapsed-ms "$max_elapsed" \
  --min-total-mib "$min_mib" 2>&1)
rc=$?
set -e

if [ "$rc" = 0 ]; then
  elapsed=$(python3 - "$manifest" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("total_elapsed_ms", "unknown"))
PY
)
  bytes=$(python3 - "$manifest" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("total_bytes", 0))
PY
)
  echo "TASK_OK=1 checkpoint_release_valid=1 elapsed_ms=$elapsed total_bytes=$bytes"
else
  reason=$(printf '%s\n' "$validation" | tr '\n' ' ' | cut -c1-700)
  echo "TASK_OK=0 checkpoint_release_valid=0 reason=$reason"
fi
printf '%s\n' "$validation"

