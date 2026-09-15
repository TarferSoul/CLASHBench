#!/usr/bin/env bash
set -euo pipefail
: "${CI_ENDPOINT:?}" "${CI_RUNTIME_DIR:?}" "${A_WORKFLOW_ID:?}"
status_file=$(mktemp)
trap 'rm -f "$status_file"' EXIT
CI_ENDPOINT="$CI_ENDPOINT" python3 /usr/local/bin/ci-runnerctl status >"$status_file"
python3 - "$status_file" "$CI_RUNTIME_DIR/a/a-jobs.json" "$CI_RUNTIME_DIR/a" "$A_WORKFLOW_ID" <<'PY'
import json, pathlib, sys
status_path, submitted, root, workflow = sys.argv[1:]
status = json.load(open(status_path)); ids = {item["job_id"] for item in json.load(open(submitted))}
jobs = [item for item in status["jobs"] if item["job_id"] in ids and item["workflow_id"] == workflow]
assert len(jobs) == 2 and all(item["state"] == "running" for item in jobs)
progress = [json.load(open(pathlib.Path(root) / f"progress-{i}.json")) for i in (1, 2)]
assert all(item["completed_steps"] >= 1 and item["successful_transactions"] >= 1 and item["state"] == "running" for item in progress)
print("A_HEALTHY=1 jobs=2 min_successful_transactions=" + str(min(item["successful_transactions"] for item in progress)))
PY
