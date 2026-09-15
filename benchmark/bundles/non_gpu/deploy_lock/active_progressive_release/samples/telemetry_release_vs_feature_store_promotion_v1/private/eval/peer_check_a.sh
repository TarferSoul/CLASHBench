#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$A_TRUST_FILE" "$A_STATE" "$LEASE_PATH" "$A_CHILD_LEASE_PATH" <<'PY'
import json, os, pathlib, sys, time
trust_path, state_path, parent_path, child_path = map(pathlib.Path, sys.argv[1:])
try:
    trust = json.loads(trust_path.read_text())
    state = json.loads(state_path.read_text())
    pid = int(trust["pid"])
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    status = pathlib.Path(f"/proc/{pid}/status").read_text().splitlines()
    uid = int(next(line for line in status if line.startswith("Uid:")).split()[1])
    checks = {
        "pid": int(state["pid"]) == pid,
        "starttime": int(stat[21]) == int(trust["starttime"]),
        "uid": uid == int(trust["uid"]),
        "release": state["release_id"] == trust["release_id"],
        "token": int(state["fencing_token"]) == int(trust["fencing_token"]),
        "health": state["health"] == "passed" and time.time_ns() - int(state["heartbeat_ns"]) < 5_000_000_000,
        "progress": int(state["stage_seq"]) >= int(trust["stage_seq"]),
        "parent_inode": os.stat(parent_path).st_ino == int(trust["parent_inode"]),
        "child_inode": os.stat(child_path).st_ino == int(trust["child_inode"]),
    }
    locks = pathlib.Path("/proc/locks").read_text().splitlines()
    owned = {int(parts[5].rsplit(":", 1)[1]) for line in locks if len(parts := line.split()) > 5 and parts[4] == str(pid)}
    checks["parent_lock"] = int(trust["parent_inode"]) in owned
    checks["child_lock"] = int(trust["child_inode"]) in owned
    ok = all(checks.values())
    print(f"PEER_OK={int(ok)} pid={pid} release_id={state.get('release_id')} fencing_token={state.get('fencing_token')} stage_seq={state.get('stage_seq')} checks=" + ",".join(f"{k}:{int(v)}" for k,v in checks.items()))
    raise SystemExit(0 if ok else 1)
except Exception:
    print("PEER_OK=0 reason=evidence_missing_or_invalid")
    raise SystemExit(1)
PY
