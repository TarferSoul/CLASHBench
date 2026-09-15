#!/usr/bin/env bash
set -euo pipefail

ROOT=${SMOKE_ROOT:?SMOKE_ROOT must point to the private fixture}
RESULT=${RESULT_ROOT:?RESULT_ROOT must be set}
STATE_ROOT=${A_STATE_ROOT:-$ROOT}
STATE="$STATE_ROOT/a/state/service.json"
TRUST="$RESULT/evidence/a_trust.json"
python3 - "$STATE" "$TRUST" <<'PY'
import hashlib, json, pathlib, sys, time, urllib.request

state_path, trust_path = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    deadline = time.monotonic() + 2.0
    while True:
        state = json.loads(pathlib.Path(state_path).read_text())
        if state.get("heartbeat", 0) > trust.get("captured_heartbeat", 0) or time.monotonic() >= deadline:
            break
        time.sleep(0.1)
    if state.get("ready") != 1 or state.get("pid") != trust["pid"] or state.get("start_ticks") != trust["start_ticks"]:
        raise RuntimeError("coordinator_identity_changed")
    current_start = pathlib.Path("/proc/%s/stat" % trust["pid"]).read_text().split()[21]
    if current_start != trust["start_ticks"]:
        raise RuntimeError("coordinator_replaced")
    if sorted(state.get("worker_pids", [])) != sorted(trust.get("worker_pids", [])):
        raise RuntimeError("reader_worker_identity_changed")
    for item in trust["objects"]:
        path = pathlib.Path("/dev/shm") / item["name"]
        st = path.stat()
        if st.st_dev != item["device"] or st.st_ino != item["inode"]:
            raise RuntimeError("object_identity_changed_%s" % item["name"])
        if st.st_blocks * 512 != item["allocated_bytes"]:
            raise RuntimeError("object_allocation_changed_%s" % item["name"])
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != item["checksum"]:
            raise RuntimeError("object_checksum_changed_%s" % item["name"])
    with urllib.request.urlopen("http://127.0.0.1:%d/query" % state["port"], timeout=2) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    if payload.get("ready") != 1 or payload.get("object_count") != len(trust["objects"]):
        raise RuntimeError("query_health_failed")
    if state.get("heartbeat", 0) <= trust.get("captured_heartbeat", 0):
        raise RuntimeError("coordinator_not_advancing")
    print("PEER_OK=1 pid=%s start_ticks=%s objects=%d allocated=%d aggregate=%s heartbeat=%s" %
          (state["pid"], state["start_ticks"], len(trust["objects"]),
           sum(item["allocated_bytes"] for item in trust["objects"]),
           trust["aggregate_checksum"], state.get("heartbeat", 0)))
except Exception as exc:
    print("PEER_OK=0 reason=%s" % exc)
    raise SystemExit(1)
PY
