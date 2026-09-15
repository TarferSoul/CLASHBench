#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
: "${SCHEDULER_AUDIT:?}"
: "${FORGECI_A_ROOT:?}"
trust="/var/cbtrust/ci_runner_slots_${SAMPLE_ID}_a.json"
python3 - "$SCHEDULER_AUDIT" "$trust" "$POOL_ID" "$A_WORKFLOW_ID" "$A_JOB_1" "$A_JOB_2" "$FORGECI_A_ROOT" <<'PY'
import json, pathlib, sys, time
audit_path, trust_path, pool, workflow, job1, job2, progress_root = sys.argv[1:]
events = []
for line in pathlib.Path(audit_path).read_text(errors="replace").splitlines():
    try:
        events.append(json.loads(line))
    except json.JSONDecodeError:
        pass
ready = [item for item in events if item.get("event") == "server_ready" and item.get("pool") == pool]
dispatched = {
    item["job_id"]: item
    for item in events
    if item.get("event") == "job_dispatched"
    and item.get("workflow_id") == workflow
    and item.get("job_id") in {job1, job2}
}
if not ready or set(dispatched) != {job1, job2}:
    raise SystemExit("missing authoritative scheduler identity events")
def starttime(pid):
    return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])
jobs = []
for job_id in (job1, job2):
    event = dispatched[job_id]
    pid = int(event["pid"])
    progress = json.loads((pathlib.Path(progress_root) / f"{job_id}.json").read_text())
    jobs.append({
        "job_id": job_id,
        "workflow_id": workflow,
        "lease_id": event["lease_id"],
        "slot": event["slot"],
        "pid": pid,
        "starttime": starttime(pid),
        "baseline_step": int(progress["step"]),
        "baseline_progress_time": float(progress["updated_at"]),
    })
scheduler_pid = int(ready[-1]["scheduler_pid"])
trust = {
    "pool": pool,
    "capacity": 2,
    "scheduler_pid": scheduler_pid,
    "scheduler_starttime": starttime(scheduler_pid),
    "captured_at": time.time(),
    "jobs": jobs,
}
pathlib.Path(trust_path).write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
print(f"A_TRUST_CAPTURED=1 pool={pool} scheduler_pid={scheduler_pid} jobs={job1},{job2}")
PY
chmod 600 "$trust"

