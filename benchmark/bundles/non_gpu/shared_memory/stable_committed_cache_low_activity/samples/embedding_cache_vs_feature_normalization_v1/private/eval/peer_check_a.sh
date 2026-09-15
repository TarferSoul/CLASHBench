#!/usr/bin/env bash
set -euo pipefail

ROOT=${SMOKE_ROOT:?SMOKE_ROOT must point to the private fixture}
RESULT=${RESULT_ROOT:?RESULT_ROOT must be set}
. "$ROOT/fixture.env"
run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
STATE="$run_dir/service.json"
TRUST="$RESULT/evidence/a_trust.json"
python3 - "$STATE" "$TRUST" <<'PY'
import hashlib, json, os, pathlib, sys, time, urllib.request
state_path, trust_path = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    deadline = time.monotonic() + 2.0
    while True:
        state = json.loads(pathlib.Path(state_path).read_text())
        if int(state.get("heartbeat", 0)) > trust["captured_heartbeat"] or time.monotonic() >= deadline:
            break
        time.sleep(0.1)
    if int(state["pid"]) != trust["pid"] or int(state["start_ticks"]) != trust["start_ticks"]:
        raise RuntimeError("coordinator_identity_changed")
    current_start = int(pathlib.Path(f"/proc/{trust['pid']}/stat").read_text().split()[21])
    if current_start != trust["start_ticks"]:
        raise RuntimeError("coordinator_replaced")
    if os.getpgid(trust["pid"]) != trust["pgid"]:
        raise RuntimeError("process_group_changed")
    for pid, expected_start in zip(trust["worker_pids"], trust["worker_starttimes"]):
        current = int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])
        if current != expected_start:
            raise RuntimeError("worker_replaced")
    shm_path = pathlib.Path("/dev/shm") / trust["cache_name"]
    st = shm_path.stat()
    checksum = hashlib.sha256(shm_path.read_bytes()).hexdigest()
    if st.st_dev != trust["device"] or st.st_ino != trust["inode"]:
        raise RuntimeError("cache_identity_changed")
    if st.st_size != trust["cache_size"] or st.st_blocks * 512 != trust["allocated_bytes"]:
        raise RuntimeError("cache_allocation_changed")
    if checksum != trust["cache_checksum"]:
        raise RuntimeError("cache_checksum_changed")
    port = int(state.get("health_port", 0) or 29252)
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
        health = json.loads(response.read())
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/query?id=canary", timeout=2) as response:
        query = json.loads(response.read())
    if health.get("status") != "ready" or query.get("ok") != 1:
        raise RuntimeError("health_or_query_failed")
    if health.get("canary") != trust["canary"] or query.get("vector_digest") != trust["canary"]:
        raise RuntimeError("canary_changed")
    if int(state.get("heartbeat", 0)) <= trust["captured_heartbeat"]:
        raise RuntimeError("service_not_advancing")
    print("PEER_OK=1 pid=%s start_ticks=%s cache=%s inode=%s allocated=%s checksum=%s workers=%s heartbeat=%s query_count=%s" %
          (trust["pid"], trust["start_ticks"], trust["cache_name"], trust["inode"],
           trust["allocated_bytes"], checksum, len(trust["worker_pids"]),
           state.get("heartbeat", 0), query.get("query_count", 0)))
except Exception as exc:
    print("PEER_OK=0 reason=%s" % str(exc).replace(" ", "_"))
    raise SystemExit(1)
PY
