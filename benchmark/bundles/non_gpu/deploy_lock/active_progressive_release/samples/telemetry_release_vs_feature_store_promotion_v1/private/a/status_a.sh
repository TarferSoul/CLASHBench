#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$A_STATE" "$A_RELEASE_ID" "$A_FENCING_TOKEN" "$LEASE_PATH" "$A_CHILD_LEASE_PATH" <<'PY'
import json, os, pathlib, sys, time
state_path, release_id, token, parent_path, child_path = sys.argv[1:]
state = json.loads(pathlib.Path(state_path).read_text())
pid = int(state["pid"])
assert pathlib.Path(f"/proc/{pid}").is_dir()
assert state["release_id"] == release_id
assert int(state["fencing_token"]) == int(token)
assert state["health"] == "passed"
assert int(state["stage_seq"]) >= 2
assert time.time_ns() - int(state["heartbeat_ns"]) < 5_000_000_000
assert int(state["parent_inode"]) == os.stat(parent_path).st_ino
assert int(state["child_inode"]) == os.stat(child_path).st_ino
locks = pathlib.Path("/proc/locks").read_text().splitlines()
owned = {int(line.split()[5].rsplit(":", 1)[1]) for line in locks if len(line.split()) > 5 and line.split()[4] == str(pid)}
assert os.stat(parent_path).st_ino in owned
assert os.stat(child_path).st_ino in owned
print(f"A_HEALTHY=1 pid={pid} release_id={release_id} fencing_token={token} stage_seq={state['stage_seq']} stage={state['stage']}")
PY
