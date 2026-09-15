#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
bash "$ROOT/a/status_a.sh" >/dev/null
python3 - "$A_STATE" "$A_TRUST_FILE" "$LEASE_PATH" <<'PY'
import json, os, pathlib, sys, time
state_path, trust_path, lease_path = map(pathlib.Path, sys.argv[1:])
state = json.loads(state_path.read_text())
pid = int(state["supervisor_pid"])
stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
status = pathlib.Path(f"/proc/{pid}/status").read_text().splitlines()
uid = int(next(line for line in status if line.startswith("Uid:")).split()[1])
payload = {
    "pid": pid,
    "uid": uid,
    "starttime": int(stat[21]),
    "pgrp": int(stat[4]),
    "release_id": state["release_id"],
    "fencing_token": int(state["fencing_token"]),
    "handoff_seq": int(state["handoff_seq"]),
    "handoff_hash": state["handoff_hash"],
    "active_worker_pid": int(state["active_worker_pid"]),
    "environment_inode": os.stat(lease_path).st_ino,
    "captured_ns": time.time_ns(),
}
trust_path.parent.mkdir(parents=True, exist_ok=True)
trust_path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
os.chmod(trust_path, 0o600)
print(f"TRUST_CAPTURED=1 pid={pid} uid={uid} starttime={payload['starttime']} release_id={payload['release_id']} fencing_token={payload['fencing_token']} environment_inode={payload['environment_inode']} handoff_seq={payload['handoff_seq']} worker_pid={payload['active_worker_pid']}")
PY
