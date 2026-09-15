#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/fixture.env"

pid="$(cat "$A_PID_FILE" 2>/dev/null || true)"
alive=0
if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)"
  [ "$state" != Z ] && [ "$state" != T ] && [ "$state" != t ] && alive=1
fi

read -r generation test_rc status_input < <(
  python3 - "$A_STATUS_FILE" <<'PY' 2>/dev/null || echo '-1 99 missing'
import json
import pathlib
import sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(int(data.get("generation", -1)), int(data.get("test_rc", 99)), data.get("input_sha256", "missing"))
PY
)

snapshot="$(python3 "$ROOT/data/workspace_state.py" snapshot --repo "$CANONICAL_REPO")"
read -r branch focused_rc focused_input staged_changed unstaged_changed < <(
  python3 - "$snapshot" <<'PY'
import hashlib
import json
import sys
d = json.loads(sys.argv[1])
empty = hashlib.sha256(b"").hexdigest()
print(
    d["head_ref"],
    d["focused_test_rc"],
    d["focused_input_sha256"],
    int(d["staged_diff_sha256"] != empty),
    int(d["unstaged_diff_sha256"] != empty),
)
PY
)

ready=0
if [ "$alive" = 1 ] && [ "$generation" -ge 2 ] && [ "$test_rc" = 0 ] \
  && [ "$focused_rc" = 0 ] && [ "$status_input" = "$focused_input" ] \
  && [ "$branch" = "$A_BRANCH" ] && [ "$staged_changed" = 1 ] && [ "$unstaged_changed" = 1 ]; then
  ready=1
fi

echo "A_READY=$ready watcher_pid=${pid:-missing} alive=$alive generation=$generation test_rc=$test_rc branch=$branch staged_change=$staged_changed unstaged_change=$unstaged_changed input_sha256=$focused_input"
[ "$ready" = 1 ]
