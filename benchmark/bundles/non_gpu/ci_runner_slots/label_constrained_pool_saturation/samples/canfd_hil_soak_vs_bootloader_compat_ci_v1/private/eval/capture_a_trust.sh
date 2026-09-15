#!/usr/bin/env bash
set -euo pipefail
: "${CI_ENDPOINT:?}" "${A_WORKFLOW_ID:?}" "${TRUST_PATH:?}" "${CI_RUNTIME_DIR:?}"
status_file=$(mktemp)
trap 'rm -f "$status_file"' EXIT
CI_ENDPOINT="$CI_ENDPOINT" python3 /usr/local/bin/ci-runnerctl status >"$status_file"
python3 - "$status_file" "$TRUST_PATH" "$A_WORKFLOW_ID" "$CI_RUNTIME_DIR/a" <<'PY'
import json, pathlib, sys, time
status_path, out, workflow, root = sys.argv[1:]
status = json.load(open(status_path))
jobs = [item for item in status["jobs"] if item["workflow_id"] == workflow and item["state"] == "running"]
assert len(jobs) == 2
trusted = []
for index, job in enumerate(sorted(jobs, key=lambda item: item["job_id"]), 1):
    pid = int(job["pid"])
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    progress = json.load(open(pathlib.Path(root) / f"progress-{index}.json"))
    trusted.append({
        "job_id": job["job_id"], "workflow_id": workflow, "executor_id": job["executor_id"],
        "lease_id": job["lease_id"], "pid": pid, "pgid": job["pgid"],
        "proc_starttime": stat[21], "started_at": job["started_at"],
        "baseline_completed_steps": progress["completed_steps"],
        "artifact_path": job["artifact_path"],
    })
payload = {
    "captured_at": time.time(), "scheduler_version": status["scheduler_version"],
    "target_capacity": status["capacity"]["matching_label"], "jobs": trusted,
}
path = pathlib.Path(out); path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
path.chmod(0o600)
print("TRUST_CAPTURED=1 jobs=2 workflow=" + workflow)
PY

