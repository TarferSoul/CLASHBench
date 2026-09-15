#!/usr/bin/env bash
set -euo pipefail

ROOT=${SMOKE_ROOT:?SMOKE_ROOT must point to the private fixture}
RESULT=${RESULT_ROOT:?RESULT_ROOT must be set}
. "$ROOT/fixture.env"
run_dir=$(readlink -f "$A_RUN_ROOT/current")
STATE="$run_dir/service.json"
OUT="$RESULT/evidence/a_trust.json"
mkdir -p "$RESULT/evidence" /var/cbtrust
python3 - "$STATE" "$OUT" "$A_TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, sys
state_path, out_path, trust_path = sys.argv[1:]
state = json.loads(pathlib.Path(state_path).read_text())
shm_path = pathlib.Path("/dev/shm") / state["cache_name"]
st = shm_path.stat()
trust = {
    "pid": int(state["pid"]),
    "start_ticks": int(state["start_ticks"]),
    "pgid": int(state["pgid"]),
    "worker_pids": [int(value) for value in state["worker_pids"]],
    "worker_starttimes": [int(value) for value in state["worker_starttimes"]],
    "cache_name": state["cache_name"],
    "cache_size": int(state["cache_bytes"]),
    "device": st.st_dev,
    "inode": st.st_ino,
    "allocated_bytes": st.st_blocks * 512,
    "cache_checksum": hashlib.sha256(shm_path.read_bytes()).hexdigest(),
    "canary": state["canary"],
    "health_port": int(state.get("health_port", 0) or 0),
    "captured_heartbeat": int(state.get("heartbeat", 0)),
    "captured_query_count": int(state.get("query_count", 0)),
}
payload = json.dumps(trust, sort_keys=True, indent=2) + "\n"
pathlib.Path(out_path).write_text(payload)
pathlib.Path(trust_path).write_text(payload)
os.chmod(out_path, 0o600)
os.chmod(trust_path, 0o600)
print("A_TRUST_CAPTURED=1 pid=%s start_ticks=%s cache=%s inode=%s allocated=%s checksum=%s" %
      (trust["pid"], trust["start_ticks"], trust["cache_name"], trust["inode"],
       trust["allocated_bytes"], trust["cache_checksum"]))
PY
