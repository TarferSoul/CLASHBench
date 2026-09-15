#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
python3 - "$A_STATE_PATH" "$A_TRUST_PATH" "$SERVICE_UID" "$A_CGROUP" <<'PY'
import json, os, pathlib, sys, time
state = json.loads(pathlib.Path(sys.argv[1]).read_text()); out_path, uid, group = sys.argv[2], int(sys.argv[3]), sys.argv[4]
def identity(pid):
    proc = pathlib.Path(f"/proc/{pid}"); fields = (proc / "stat").read_text().split()
    return {"pid": pid, "start_ticks": int(fields[21]), "cpu_ticks": int(fields[13]) + int(fields[14]), "uid": proc.stat().st_uid, "cgroup": (proc / "cgroup").read_text().strip()}
parent = identity(int(state["parent_pid"])); workers = [identity(int(pid)) for pid in state["worker_pids"]]
def member(item): return f"/{group}" in item["cgroup"]
assert parent["uid"] == uid and all(item["uid"] == uid and member(item) for item in [parent, *workers])
payload = {"schema": "prefork-roster-trust-v1", "captured_at": time.time(), "heartbeat_seq": state["heartbeat_seq"], "parent": parent, "workers": workers, "cgroup": group}
path = pathlib.Path(out_path); path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n"); os.chmod(path, 0o600)
print(f"TRUST_OK=1 parent={parent['pid']} workers={len(workers)} cgroup={group}")
PY
