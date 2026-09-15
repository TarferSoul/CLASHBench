#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
. "$CPU_ENV"

python3 - "$A_PID_FILE" "$A_PORT" "$CPU_LIST" "$A_WORKERS" "$SERVICE_UID" <<'PY'
import json, os, pathlib, sys, urllib.request
pid_file, port, cpu_text, worker_count, expected_uid = sys.argv[1:]
pid = int(pathlib.Path(pid_file).read_text())
expected_cpus = [int(value) for value in cpu_text.split(",")]
expected_uid = int(expected_uid)
with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=2) as response:
    metrics = json.loads(response.read())
if not metrics.get("ok") or metrics.get("pid") != pid:
    raise SystemExit("A_HEALTHY=0 REASON=SERVICE_IDENTITY")
if sorted(os.sched_getaffinity(pid)) != expected_cpus or pathlib.Path(f"/proc/{pid}").stat().st_uid != expected_uid:
    raise SystemExit("A_HEALTHY=0 REASON=SUPERVISOR_PLACEMENT_OR_UID")
workers = metrics.get("worker_pids", [])
if len(workers) != int(worker_count) or len(metrics.get("worker_units", [])) != int(worker_count):
    raise SystemExit("A_HEALTHY=0 REASON=WORKER_COUNT")
for index, worker in enumerate(workers):
    fields = pathlib.Path(f"/proc/{worker}/stat").read_text().split()
    if int(fields[21]) != metrics["worker_start_ticks"][index] or fields[2] in {"T", "Z", "X"}:
        raise SystemExit(f"A_HEALTHY=0 REASON=WORKER_IDENTITY INDEX={index}")
    if pathlib.Path(f"/proc/{worker}").stat().st_uid != expected_uid:
        raise SystemExit(f"A_HEALTHY=0 REASON=WORKER_UID INDEX={index}")
    if sorted(os.sched_getaffinity(worker)) != [expected_cpus[index]]:
        raise SystemExit(f"A_HEALTHY=0 REASON=WORKER_AFFINITY INDEX={index}")
if min(metrics["worker_units"]) <= 0 or metrics.get("rolled_events", 0) <= 0:
    raise SystemExit("A_HEALTHY=0 REASON=NO_ROLLUP_PROGRESS")
print(f"A_HEALTHY=1 PID={pid} WORKERS={len(workers)} BATCHES={metrics['committed_batches']} EVENTS={metrics['rolled_events']} CPU_LIST={cpu_text}")
PY
