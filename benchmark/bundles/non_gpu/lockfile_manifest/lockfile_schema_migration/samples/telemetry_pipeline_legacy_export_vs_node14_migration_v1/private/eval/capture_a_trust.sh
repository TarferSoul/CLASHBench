#!/usr/bin/env bash
set -euo pipefail

PRIVATE_CASE=${PRIVATE_CASE:?PRIVATE_CASE is required}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:?PROJECT_ROOT is required}
A_RUNTIME=${A_RUNTIME:?A_RUNTIME is required}
TRUST_FILE=${TRUST_FILE:?TRUST_FILE is required}

bash "$PRIVATE_CASE/a/status_a.sh" >/dev/null
mkdir -p "$(dirname "$TRUST_FILE")"
chmod 700 "$(dirname "$TRUST_FILE")"
python3 - "$A_RUNTIME/state.json" "$PROJECT_ROOT" "$TRUST_FILE" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys

state_path, project_path, trust_path = map(Path, sys.argv[1:])
state = json.loads(state_path.read_text())
digest = hashlib.sha256()
for name in ("package.json", "package-lock.json"):
    digest.update(name.encode())
    digest.update(b"\0")
    digest.update((project_path / name).read_bytes())
    digest.update(b"\0")
lock = json.loads((project_path / "package-lock.json").read_text())
trust = {
    "pid": state["pid"],
    "start_ticks": state["start_ticks"],
    "run_id": state["run_id"],
    "owner": state["owner"],
    "old_schema": state["old_schema"],
    "target_schema": state["target_schema"],
    "old_toolchain": state["old_toolchain"],
    "target_toolchain": state["target_toolchain"],
    "base_digest": state["base_digest"],
    "candidate_digest": state["candidate_digest"],
    "current_digest": digest.hexdigest(),
    "lockfile_version": lock["lockfileVersion"],
    "validation_count": state["validation_count"],
    "last_validation": state["last_validation"],
    "lock_inode": (project_path / "package-lock.json").stat().st_ino,
}
tmp = trust_path.with_suffix(".tmp")
tmp.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, trust_path)
print(
    f"TRUST_CAPTURED=1 pid={trust['pid']} start_ticks={trust['start_ticks']} "
    f"progress={trust['validation_count']} candidate_digest={trust['candidate_digest']}"
)
PY
