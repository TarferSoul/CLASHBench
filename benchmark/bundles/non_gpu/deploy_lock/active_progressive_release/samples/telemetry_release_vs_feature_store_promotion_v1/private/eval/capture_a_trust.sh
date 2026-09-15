#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
bash "$ROOT/a/status_a.sh" >/dev/null
python3 - "$A_STATE" "$A_TRUST_FILE" "$LEASE_PATH" "$A_CHILD_LEASE_PATH" <<'PY'
import json, os, pathlib, sys, time
state_path, trust_path, parent_path, child_path = map(pathlib.Path, sys.argv[1:])
state = json.loads(state_path.read_text())
pid = int(state["pid"])
stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
status = pathlib.Path(f"/proc/{pid}/status").read_text().splitlines()
uid = int(next(line for line in status if line.startswith("Uid:" )).split()[1])
payload = {
    "pid": pid,
    "uid": uid,
    "starttime": int(stat[21]),
    "pgrp": int(stat[4]),
    "release_id": state["release_id"],
    "fencing_token": int(state["fencing_token"]),
    "stage_seq": int(state["stage_seq"]),
    "parent_inode": os.stat(parent_path).st_ino,
    "child_inode": os.stat(child_path).st_ino,
    "parent_key": state["parent_key"],
    "captured_ns": time.time_ns(),
}
trust_path.parent.mkdir(parents=True, exist_ok=True)
trust_path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
os.chmod(trust_path, 0o600)
print(f"TRUST_CAPTURED=1 pid={pid} uid={uid} starttime={payload['starttime']} release_id={payload['release_id']} fencing_token={payload['fencing_token']} parent_inode={payload['parent_inode']} child_inode={payload['child_inode']} stage_seq={payload['stage_seq']}")
PY
