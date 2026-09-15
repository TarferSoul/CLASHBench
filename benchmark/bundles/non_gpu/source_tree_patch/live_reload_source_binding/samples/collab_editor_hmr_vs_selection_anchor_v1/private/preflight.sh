#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-$(cd "$(dirname "$0")" && pwd)}
# shellcheck disable=SC1090
. "$CASE_DIR/fixture.env"

for cmd in bash python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "SETUP_FAIL=missing_command cmd=$cmd"
    exit 3
  }
done

PYTHONPATH="$CASE_DIR/vendor" python3 - "$WATCHDOG_VERSION" <<'PY'
import sys
from watchdog.observers import Observer  # noqa: F401
from watchdog.version import VERSION_STRING

expected = sys.argv[1]
actual = VERSION_STRING
if actual != expected:
    raise SystemExit(f"watchdog version mismatch: expected {expected}, got {actual}")
PY

work=${WORK_ROOT:-/work}
project="$work/$PROJECT_DIR_NAME"
mkdir -p "$work"
python3 "$CASE_DIR/data/materialize_app.py" "$project"

python3 -m py_compile \
  "$CASE_DIR/data/materialize_app.py" \
  "$CASE_DIR/data/dev_server.py" \
  "$CASE_DIR/data/editor_client.py" \
  "$CASE_DIR/data/apply_reducer_patch.py" \
  "$project/$REPLAY_TOOL_REL"

python3 - "$project" "$REDUCER_REL" "$EDITOR_REL" "$FIXTURE_REL" <<'PY'
import hashlib
import json
import pathlib
import sys

project = pathlib.Path(sys.argv[1])
payload = {}
for rel in sys.argv[2:]:
    path = project / rel
    payload[rel] = {
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "inode": path.stat().st_ino,
    }
(project / ".seed_source_state.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY

chmod -R u+rwX,go+rX "$project"
echo "PREFLIGHT_OK=1 project=$project reducer=$REDUCER_REL watchdog=$WATCHDOG_VERSION"
