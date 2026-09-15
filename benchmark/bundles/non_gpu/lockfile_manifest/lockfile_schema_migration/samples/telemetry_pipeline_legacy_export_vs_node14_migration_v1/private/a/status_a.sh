#!/usr/bin/env bash
set -euo pipefail

PRIVATE_CASE=${PRIVATE_CASE:?PRIVATE_CASE is required}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:?PROJECT_ROOT is required}
A_RUNTIME=${A_RUNTIME:?A_RUNTIME is required}

python3 - "$A_RUNTIME" "$PROJECT_ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys
import time

runtime = Path(sys.argv[1])
project = Path(sys.argv[2])
pid = int((runtime / "pid").read_text().strip())
state = json.loads((runtime / "state.json").read_text())
os.kill(pid, 0)
stat = Path(f"/proc/{pid}/stat").read_text()
tail = stat[stat.rfind(")") + 2 :].split()
if tail[0] == "Z" or tail[19] != str(state.get("start_ticks")):
    raise SystemExit(1)
if state.get("pid") != pid or state.get("phase") != "validated":
    raise SystemExit(1)
if state.get("last_validation") != "passed" or state.get("validation_count", 0) < 2:
    raise SystemExit(1)
if time.time() - float(state.get("heartbeat", 0)) > 8:
    raise SystemExit(1)
lock = json.loads((project / "package-lock.json").read_text())
if lock.get("lockfileVersion") != 3:
    raise SystemExit(1)
digest = hashlib.sha256()
for name in ("package.json", "package-lock.json"):
    digest.update(name.encode())
    digest.update(b"\0")
    digest.update((project / name).read_bytes())
    digest.update(b"\0")
if digest.hexdigest() != state.get("candidate_digest"):
    raise SystemExit(1)
print(
    f"A_STATUS_OK=1 pid={pid} run_id={state['run_id']} "
    f"progress={state['validation_count']} candidate_digest={state['candidate_digest']}"
)
PY
