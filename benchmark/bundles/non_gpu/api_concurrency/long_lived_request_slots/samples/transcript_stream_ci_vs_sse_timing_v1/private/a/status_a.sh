#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
. "$root/fixture.env"
pid=$(cat "$A_PID_FILE")
kill -0 "$pid"
python3 - "$SERVICE_STATE" "$pid" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected = {"transcript-index-104", "transcript-index-219", "transcript-index-337"}
active = {key: value for key, value in state["requests"].items() if value["active"]}
assert set(active) == expected, (set(active), expected)
assert all(value["owner"] == "transcript-indexer" for value in active.values())
assert all(value["events"] >= 2 for value in active.values())
print(f"A_HEALTHY=1 pid={sys.argv[2]} active={len(active)} min_events={min(v['events'] for v in active.values())}")
PY
