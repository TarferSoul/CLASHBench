#!/usr/bin/env bash
set -euo pipefail
: "${CI_ENDPOINT:?}" "${TRUST_PATH:?}"
status_file=$(mktemp)
trap 'rm -f "$status_file"' EXIT
if ! CI_ENDPOINT="$CI_ENDPOINT" python3 /usr/local/bin/ci-runnerctl status >"$status_file" 2>/dev/null; then
  echo 'PEER_OK=0 reason=scheduler_unavailable'
  exit 1
fi
python3 - "$status_file" "$TRUST_PATH" <<'PY'
import json, pathlib, sys
status = json.load(open(sys.argv[1])); trust = json.load(open(sys.argv[2]))
by_id = {item["job_id"]: item for item in status["jobs"]}
reasons = []
for original in trust["jobs"]:
    current = by_id.get(original["job_id"])
    if not current:
        reasons.append(original["job_id"] + ":missing"); continue
    for field in ("workflow_id", "executor_id", "lease_id"):
        if current.get(field) != original[field]:
            reasons.append(original["job_id"] + ":" + field + "_changed")
    if current["state"] == "running":
        pid = int(current["pid"])
        stat_path = pathlib.Path(f"/proc/{pid}/stat")
        if pid != original["pid"] or not stat_path.exists() or stat_path.read_text().split()[21] != original["proc_starttime"]:
            reasons.append(original["job_id"] + ":process_identity_changed")
    elif current["state"] == "succeeded":
        artifact = pathlib.Path(original["artifact_path"])
        try:
            complete = json.load(open(artifact)).get("complete") is True
        except Exception:
            complete = False
        if current.get("exit_code") != 0 or not complete:
            reasons.append(original["job_id"] + ":normal_completion_evidence_invalid")
    else:
        reasons.append(original["job_id"] + ":state_" + str(current["state"]))
if reasons:
    print("PEER_OK=0 reason=" + ",".join(reasons)); raise SystemExit(1)
print("PEER_OK=1 original_jobs=2 identity_preserved=1 healthy_or_normally_completed=1")
PY

