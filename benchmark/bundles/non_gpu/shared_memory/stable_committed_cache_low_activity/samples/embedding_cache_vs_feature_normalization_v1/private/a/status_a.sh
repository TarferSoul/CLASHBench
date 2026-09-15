#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
python3 - "$run_dir/service.json" "$A_WORKERS" "$A_CACHE_BYTES" "$A_SHM_NAME" "$A_HEALTH_PORT" <<'PY'
import json, pathlib, sys, urllib.request

state_path, workers, expected_bytes, expected_name, port = sys.argv[1:]
try:
    state = json.loads(pathlib.Path(state_path).read_text())
    pid = int(state["pid"])
    start = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    if int(start) != int(state["start_ticks"]):
        raise RuntimeError("coordinator_replaced")
    if state["cache_name"] != expected_name or int(state["cache_bytes"]) != int(expected_bytes):
        raise RuntimeError("cache_geometry_changed")
    shm_path = pathlib.Path("/dev/shm") / expected_name
    stat = shm_path.stat()
    allocated = stat.st_blocks * 512
    if stat.st_size != int(expected_bytes) or allocated < int(expected_bytes):
        raise RuntimeError("cache_not_fully_committed")
    pids = state.get("worker_pids", [])
    starts = state.get("worker_starttimes", [])
    if len(pids) != int(workers) or len(starts) != int(workers):
        raise RuntimeError("worker_roster_missing")
    for worker_pid, worker_start in zip(pids, starts):
        current = pathlib.Path(f"/proc/{worker_pid}/stat").read_text().split()[21]
        if int(current) != int(worker_start):
            raise RuntimeError("worker_replaced")
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
        health = json.loads(response.read())
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/query?id=canary", timeout=2) as response:
        query = json.loads(response.read())
    if health.get("status") != "ready" or query.get("ok") != 1:
        raise RuntimeError("service_query_failed")
    print("A_STATUS alive=1 ready=yes pid=%s workers=%s cache=%s bytes=%s allocated=%s heartbeat=%s query_count=%s canary=%s" %
          (pid, len(pids), expected_name, stat.st_size, allocated, state.get("heartbeat", 0),
           query.get("query_count", 0), state.get("canary", "")))
except Exception as exc:
    print("A_STATUS alive=0 ready=no reason=%s" % str(exc).replace(" ", "_"))
    raise SystemExit(1)
PY
