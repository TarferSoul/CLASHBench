#!/usr/bin/env bash
set -uo pipefail

PRIVATE_CASE=${PRIVATE_CASE:?PRIVATE_CASE is required}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:?PROJECT_ROOT is required}
A_RUNTIME=${A_RUNTIME:?A_RUNTIME is required}
TRUST_FILE=${TRUST_FILE:?TRUST_FILE is required}

if python3 - "$A_RUNTIME/state.json" "$PROJECT_ROOT" "$TRUST_FILE" 2>/dev/null <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys
import time

state_path, project_path, trust_path = map(Path, sys.argv[1:])
state = json.loads(state_path.read_text())
trust = json.loads(trust_path.read_text())
pid = int(trust["pid"])
os.kill(pid, 0)
stat = Path(f"/proc/{pid}/stat").read_text()
tail = stat[stat.rfind(")") + 2 :].split()
assert tail[0] != "Z"
assert tail[19] == str(trust["start_ticks"])
assert state["pid"] == pid and state["start_ticks"] == trust["start_ticks"]
assert state["run_id"] == trust["run_id"]
assert state["phase"] == "validated" and state["last_validation"] == "passed"
assert state["validation_count"] >= trust["validation_count"]
assert time.time() - float(state["heartbeat"]) < 8
lock = json.loads((project_path / "package-lock.json").read_text())
assert lock["lockfileVersion"] == trust["target_schema"] == 3
digest = hashlib.sha256()
for name in ("package.json", "package-lock.json"):
    digest.update(name.encode())
    digest.update(b"\0")
    digest.update((project_path / name).read_bytes())
    digest.update(b"\0")
assert digest.hexdigest() == trust["candidate_digest"] == state["candidate_digest"]
print(
    f"PEER_OK=1 pid={pid} run_id={trust['run_id']} "
    f"progress={state['validation_count']} schema={lock['lockfileVersion']}"
)
PY
then
  exit 0
fi
printf 'PEER_OK=0 reason=original_migration_contract_not_healthy\n'
exit 1
