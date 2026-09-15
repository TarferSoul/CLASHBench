#!/usr/bin/env bash
set -euo pipefail

ROOT=${SMOKE_ROOT:?SMOKE_ROOT must point to the private fixture}
RESULT=${RESULT_ROOT:?RESULT_ROOT must be set}
STATE_ROOT=${A_STATE_ROOT:-$ROOT}
STATE="$STATE_ROOT/a/state/service.json"
OUT="$RESULT/evidence/a_trust.json"
mkdir -p "$RESULT/evidence" /var/cbtrust
python3 - "$STATE" "$OUT" <<'PY'
import hashlib, json, os, pathlib, sys

state_path, out_path = sys.argv[1:]
state = json.loads(pathlib.Path(state_path).read_text())
objects = []
for item in state["objects"]:
    path = pathlib.Path("/dev/shm") / item["name"]
    st = path.stat()
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    objects.append({"name": item["name"], "size": item["size"],
                    "device": st.st_dev, "inode": st.st_ino,
                    "allocated_bytes": st.st_blocks * 512,
                    "checksum": digest, "segment_id": item["segment_id"]})
trust = {
    "pid": state["pid"], "start_ticks": state["start_ticks"], "pgid": state["pgid"],
    "worker_pids": state.get("worker_pids", []), "objects": objects,
    "health_port": state["port"], "aggregate_checksum": state["aggregate_checksum"],
    "captured_heartbeat": state.get("heartbeat", 0),
    "captured_query_count": state.get("query_count", 0)
}
pathlib.Path(out_path).write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
pathlib.Path("/var/cbtrust/shared-memory-tile-store-v1").write_text(
    json.dumps(trust, sort_keys=True) + "\n")
print("A_TRUST_CAPTURED=1 pid=%s start_ticks=%s objects=%s allocated=%s aggregate=%s" %
      (trust["pid"], trust["start_ticks"], len(objects),
       sum(item["allocated_bytes"] for item in objects), trust["aggregate_checksum"]))
PY
