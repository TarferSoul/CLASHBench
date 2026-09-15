#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
: "${FORGECI_A_ROOT:?}"
status_json=$(forgeci status)
python3 - "$A_JOB_1" "$A_JOB_2" "$FORGECI_A_ROOT" "$status_json" <<'PY'
import json, pathlib, sys
job1, job2, root, raw = sys.argv[1:]
status = json.loads(raw)
if status.get("busy_slots") != status.get("capacity") or status.get("capacity") != 2:
    raise SystemExit(1)
active = {item["job_id"]: item for item in status.get("active", [])}
if set(active) != {job1, job2}:
    raise SystemExit(1)
steps = {}
for job_id in (job1, job2):
    item = json.loads((pathlib.Path(root) / f"{job_id}.json").read_text())
    if item.get("step", 0) < 1 or item.get("pid") != active[job_id].get("pid"):
        raise SystemExit(1)
    steps[job_id] = item["step"]
print(f"A_HEALTHY=1 busy_slots=2 capacity=2 jobs={job1},{job2} steps={steps[job1]},{steps[job2]}")
PY

