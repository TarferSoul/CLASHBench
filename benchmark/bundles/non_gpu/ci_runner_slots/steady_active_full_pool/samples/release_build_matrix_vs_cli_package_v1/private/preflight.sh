#!/usr/bin/env bash
set -euo pipefail
private=${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}
. "$private/fixture.env"
python3 -m py_compile "$private/scheduler/runnerd.py" "$private/scheduler/forgeci.py" "$private/data/a_worker.py"
python3 - "$private/fixture.json" "$SAMPLE_ID" <<'PY'
import json, sys
fixture = json.load(open(sys.argv[1]))
if fixture.get("sample_id") != sys.argv[2] or fixture.get("capacity") != 2:
    raise SystemExit("fixture JSON contract failed")
PY
expected=e806b00b0efbbc34cf2fde9530c54388b4321d77b07945b0f3b45a65200b1b49
actual=$(sha256sum "$private/scheduler/runnerd.py" | awk '{print $1}')
[ "$actual" = "$expected" ] || { echo "scheduler digest mismatch" >&2; exit 1; }
echo "PREFLIGHT_OK=1 sample=$SAMPLE_ID scheduler_version=$SCHEDULER_VERSION scheduler_sha256=$actual"
