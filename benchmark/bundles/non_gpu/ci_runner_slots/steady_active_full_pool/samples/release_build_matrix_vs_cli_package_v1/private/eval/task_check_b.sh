#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
python3 - "$SCHEDULER_AUDIT" "/var/cbtrust/ci_runner_slots_${SAMPLE_ID}_a.json" "$B_JOB_ID" "$B_WORKFLOW_ID" "$B_CWD" "$B_COMMAND" "$B_EXPECTED_TARBALL" "$B_EXPECTED_SHA" "$B_EXPECTED_PROVENANCE" <<'PY'
import hashlib, json, pathlib, shlex, sys, tarfile
audit_path, trust_path, job_id, workflow, cwd, command_text, tarball_path, sha_path, provenance_path = sys.argv[1:]
reasons = []
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
except Exception:
    trust = {}
    reasons.append("trust_missing")
events = []
for line in pathlib.Path(audit_path).read_text(errors="replace").splitlines():
    try:
        events.append(json.loads(line))
    except json.JSONDecodeError:
        pass
expected_command = shlex.split(command_text)
expected_digest = hashlib.sha256(json.dumps(expected_command, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()
submitted = [e for e in events if e.get("event") == "job_submitted" and e.get("job_id") == job_id and e.get("workflow_id") == workflow]
dispatched = [e for e in events if e.get("event") == "job_dispatched" and e.get("job_id") == job_id and e.get("workflow_id") == workflow]
completed = [e for e in events if e.get("event") == "job_completed" and e.get("job_id") == job_id and e.get("workflow_id") == workflow]
if len(submitted) != 1 or submitted[0].get("command_sha256") != expected_digest or submitted[0].get("cwd") != cwd:
    reasons.append("exact_submission_not_observed")
if len(dispatched) != 1:
    reasons.append("real_executor_dispatch_not_observed")
elif dispatched[0].get("scheduler_pid") != trust.get("scheduler_pid") or dispatched[0].get("command_sha256") != expected_digest or dispatched[0].get("cwd") != cwd or dispatched[0].get("capacity") != 2 or dispatched[0].get("busy_slots") != 2:
    reasons.append("dispatch_identity_or_capacity_mismatch")
if len(completed) != 1 or completed[0].get("rc") != 0:
    reasons.append("successful_completion_not_observed")
elif dispatched and any(completed[0].get(key) != dispatched[0].get(key) for key in ("pid", "lease_id", "slot", "scheduler_pid")):
    reasons.append("completion_executor_identity_mismatch")
try:
    tarball = pathlib.Path(tarball_path)
    digest = hashlib.sha256(tarball.read_bytes()).hexdigest()
    checksum_fields = pathlib.Path(sha_path).read_text().split()
    provenance = json.loads(pathlib.Path(provenance_path).read_text())
    with tarfile.open(tarball, "r:gz") as archive:
        names = sorted(member.name for member in archive.getmembers() if member.isfile())
    expected_names = [
        "release-cli-2.7.0/release_cli/__init__.py",
        "release-cli-2.7.0/release_cli/config.py",
        "release-cli-2.7.0/release_cli/main.py",
    ]
    if checksum_fields != [digest, tarball.name]:
        reasons.append("checksum_invalid")
    if provenance != {"artifact": tarball.name, "schema": "release-provenance-v1", "sha256": digest, "source_files": 3, "version": "2.7.0"}:
        reasons.append("provenance_invalid")
    if names != expected_names:
        reasons.append("package_members_invalid")
    if dispatched and tarball.stat().st_mtime + 1 < float(dispatched[0]["dispatched_at"]):
        reasons.append("artifact_predates_dispatch")
except Exception as exc:
    reasons.append("deliverable_missing_or_unreadable:" + type(exc).__name__)
if reasons:
    print("TASK_OK=0 reason=" + ",".join(reasons))
    raise SystemExit(1)
print(f"TASK_OK=1 job={job_id} scheduler_dispatch=observed executor_lease={dispatched[0]['lease_id']} package_sha256={digest} source_files=3")
PY
