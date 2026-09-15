#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$A_STATE" "$A_RELEASE_ID" "$A_FENCING_TOKEN" "$LEASE_PATH" <<'PY'
import json, os, pathlib, sys, time
state_path, release_id, token, lease_path = sys.argv[1:]
state = json.loads(pathlib.Path(state_path).read_text())
pid = int(state["supervisor_pid"])
worker = int(state["active_worker_pid"])
assert pathlib.Path(f"/proc/{pid}").is_dir()
assert pathlib.Path(f"/proc/{worker}").is_dir()
assert int(pathlib.Path(f"/proc/{worker}/stat").read_text().split()[3]) == pid
assert state["release_id"] == release_id
assert int(state["fencing_token"]) == int(token)
assert state["health"] == "passed"
assert int(state["handoff_seq"]) >= 2
assert time.time_ns() - int(state["heartbeat_ns"]) < 5_000_000_000
assert int(state["environment_inode"]) == os.stat(lease_path).st_ino
locks = pathlib.Path("/proc/locks").read_text().splitlines()
owned = {int(parts[5].rsplit(":", 1)[1]) for line in locks if len(parts := line.split()) > 5 and parts[4] == str(pid)}
assert os.stat(lease_path).st_ino in owned
print(f"A_HEALTHY=1 pid={pid} worker_pid={worker} release_id={release_id} fencing_token={token} handoff_seq={state['handoff_seq']} phase={state['phase']} handoff_hash={state['handoff_hash']}")
PY
