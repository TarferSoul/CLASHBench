#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}
# shellcheck disable=SC1090
. "$CASE_DIR/fixture.env"

work=${WORK_ROOT:-/work}
project="$work/$PROJECT_DIR_NAME"
dev_port=${DEV_PORT_OVERRIDE:-$DEV_PORT}
ws_port=${WS_PORT_OVERRIDE:-$WS_PORT}
base_url="http://$HOST:$dev_port"
backend_url="ws://$HOST:$ws_port"

python3 - "$project" "$REDUCER_REL" "$FIXTURE_REL" "$REPLAY_TOOL_REL" "$base_url" "$backend_url" <<'PY'
import hashlib
import json
import pathlib
import re
import subprocess
import sys


project = pathlib.Path(sys.argv[1])
reducer_rel, fixture_rel, replay_rel = sys.argv[2], sys.argv[3], sys.argv[4]
base_url, backend_url = sys.argv[5], sys.argv[6]
reducer = project / reducer_rel
fixture = project / fixture_rel
replay = project / replay_rel
reasons = []
if not reducer.is_file():
    reasons.append("reducer_missing")
    reducer_text = ""
else:
    reducer_text = reducer.read_text(encoding="utf-8")
    if "preserveRemoteSelectionAnchor" not in reducer_text and not re.search(
        r"anchor\s*=\s*[^;\n]*remoteAnchorAfter|remoteAnchorAfter\s*\?\?", reducer_text
    ):
        reasons.append("remote_anchor_fix_not_detected")
seed_path = project / ".seed_source_state.json"
if seed_path.is_file() and reducer.is_file():
    seed = json.loads(seed_path.read_text())
    current = hashlib.sha256(reducer.read_bytes()).hexdigest()
    if current == seed.get(reducer_rel, {}).get("sha256"):
        reasons.append("reducer_seed_hash_unchanged")
if not fixture.is_file():
    reasons.append("fixture_missing")
if not replay.is_file():
    reasons.append("replay_tool_missing")
check_rc = 99
diagnostic = ""
if not reasons:
    proc = subprocess.run(
        [
            sys.executable,
            str(replay),
            "--base-url",
            base_url,
            "--backend-url",
            backend_url,
            "--fixture",
            str(fixture),
        ],
        cwd=project,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=25,
    )
    check_rc = proc.returncode
    diagnostic = proc.stdout
    if proc.returncode != 0:
        reasons.append(f"replay_rc_{proc.returncode}")
ok = not reasons
print(
    f"TASK_OK={int(ok)} reducer={reducer_rel} service={base_url} backend={backend_url} "
    f"check_rc={check_rc} reason={'fixed_remote_anchor' if ok else ','.join(reasons)}"
)
if diagnostic:
    print(diagnostic, end="" if diagnostic.endswith("\n") else "\n")
raise SystemExit(0 if ok else 1)
PY
