#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/fixture.env"

bash "$ROOT/a/status_a.sh" >/dev/null
python3 "$ROOT/data/workspace_state.py" capture \
  --repo "$CANONICAL_REPO" --status "$A_STATUS_FILE" --pid-file "$A_PID_FILE" \
  --out "$A_TRUST_FILE" >/dev/null
python3 - "$A_TRUST_FILE" <<'PY'
import json
import pathlib
import sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(
    "A_TRUST_OK=1"
    f" watcher_pid={d['a_pid']} starttime={d['a_starttime']}"
    f" head_ref={d['head_ref']} head_oid={d['head_oid']} index_tree={d['index_tree']}"
    f" staged_diff_sha256={d['staged_diff_sha256']}"
    f" unstaged_diff_sha256={d['unstaged_diff_sha256']}"
    f" focused_input_sha256={d['focused_input_sha256']}"
    f" focused_test_rc={d['focused_test_rc']} generation={d['route_validation_generation']}"
)
PY
