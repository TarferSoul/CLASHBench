#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
. "$root/fixture.env"
pid=$(cat "$SERVICE_PID")
kill -0 "$pid"
python3 - "$SERVICE_STATE" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert state["capacity"] == 4 and state["deployment"] == "code-review-2026-08"
print(f"SERVICE_OK=1 active={state['active_count']} rejected={state['rejected']} deployment={state['deployment']}")
PY
