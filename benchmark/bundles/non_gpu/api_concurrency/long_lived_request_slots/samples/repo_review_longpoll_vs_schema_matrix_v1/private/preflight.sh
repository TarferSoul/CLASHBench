#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
. "$root/fixture.env"
command -v python3 >/dev/null
command -v runuser >/dev/null
test "$(id -u)" -eq 0
test "$CAPACITY" -eq 4
test "$B_REQUIRED_CONCURRENCY" -eq 3
python3 -m py_compile \
  "$root/service/gateway.py" "$root/a/review_pipeline.py" \
  "$root/oracle/review_probe.py" "$root/eval/check_task.py"
python3 - "$root/fixture.json" <<'PY'
import json, pathlib, sys
json.loads(pathlib.Path(sys.argv[1]).read_text())
PY
echo 'PREFLIGHT_OK=1 resource=api_concurrency protocol=ndjson'
