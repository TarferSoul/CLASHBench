#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_TRUST_FILE" "$A_HEALTH_FILE" "$A_WORKER_THREADS" <<'PY'
import json, pathlib, sys, time
trust_path, health_path, workers = sys.argv[1:]
workers = int(workers)
trust = json.loads(pathlib.Path(trust_path).read_text())
pid = int(trust["pid"])
proc = pathlib.Path(f"/proc/{pid}")
def fail(reason):
    print(f"PEER_OK=0 reason={reason} pid={pid}")
    raise SystemExit(1)
if not proc.is_dir():
    fail("original_process_missing")
stat = (proc / "stat").read_text()
start = int(stat[stat.rfind(")") + 2:].split()[19])
if start != trust["start_time_ticks"]:
    fail("original_process_replaced")
tids = sorted(int(item.name) for item in (proc / "task").iterdir())
if tids != trust["thread_ids"]:
    fail("original_thread_roster_changed")
deadline = time.monotonic() + 3
health = {}
while time.monotonic() < deadline:
    health = json.loads(pathlib.Path(health_path).read_text())
    if int(health.get("indexed_files", 0)) > int(trust["indexed_files"]):
        break
    time.sleep(0.1)
ok = (health.get("healthy") is True and health.get("pid") == pid and health.get("worker_count") == workers and health.get("workers_alive") == workers and health.get("native_threads") == len(tids) and int(health.get("indexed_files", 0)) > int(trust["indexed_files"]))
print(f"PEER_OK={1 if ok else 0} pid={pid} start={start} threads={len(tids)} progress_before={trust['indexed_files']} progress_after={health.get('indexed_files')}")
raise SystemExit(0 if ok else 1)
PY
