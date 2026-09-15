#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
. "$root/fixture.env"
pid=$(cat "$A_PID_FILE")
kill -0 "$pid"
python3 - "$SERVICE_STATE" "$pid" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected = {"review-core-9af2", "review-auth-81bd", "review-cache-4c17", "review-cli-d202"}
active = {key: value for key, value in state["requests"].items() if value["active"]}
assert set(active) == expected, (set(active), expected)
assert all(value["owner"] == "repository-review-pipeline" for value in active.values())
assert all(value["deployment"] == "code-review-2026-08" for value in active.values())
assert all(value["token_index"] >= 2 for value in active.values())
print(f"A_HEALTHY=1 pid={sys.argv[2]} active={len(active)} min_tokens={min(v['token_index'] for v in active.values())}")
PY
