#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

command -v python3 >/dev/null
command -v setpriv >/dev/null
command -v feature-cache-tool >/dev/null
python3 -m py_compile /usr/local/bin/feature-cache-tool
python3 - "$PRIVATE_ROOT/data/validation_split.json" "$B_ARTIFACT_BYTES" <<'PY'
import json, pathlib, sys
recipe = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert recipe["artifact_bytes"] == int(sys.argv[2])
assert recipe["split"] == "validation-042"
assert len(recipe["feature_columns"]) == 5
PY
feature-cache-tool plan --recipe "$PRIVATE_ROOT/data/validation_split.json" >/tmp/feature_cache_plan.json
echo "PREFLIGHT_OK=1 cache_limit=$CACHE_LIMIT_BYTES a_stage=$A_STAGE_BYTES b_stage=$B_ARTIFACT_BYTES"
