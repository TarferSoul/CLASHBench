#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
python3 - "$SCHEDULER_AUDIT" "/var/cbtrust/ci_runner_slots_${SAMPLE_ID}_a.json" "$B_JOB_ID" "$B_WORKFLOW_ID" "$B_CWD" "$B_COMMAND" "$B_EXPECTED_JSON" "$B_EXPECTED_JUNIT" <<'PY'
import hashlib, json, pathlib, shlex, sys, xml.etree.ElementTree as ET
audit_path, trust_path, job_id, workflow, cwd, command_text, report_path, junit_path = sys.argv[1:]
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
    report_file = pathlib.Path(report_path)
    report = json.loads(report_file.read_text())
    files = [item.get("file") for item in report.get("contracts", [])]
    if report.get("schema") != "api-contract-report-v1" or report.get("contract_count") != 4 or report.get("errors") != [] or files != ["auth.json", "catalog.json", "events.json", "users.json"]:
        reasons.append("schema_report_invalid")
    suite = ET.parse(junit_path).getroot()
    if suite.tag != "testsuite" or suite.get("tests") != "4" or suite.get("failures") != "0" or len(suite.findall("testcase")) != 4:
        reasons.append("junit_report_invalid")
    if dispatched and report_file.stat().st_mtime + 1 < float(dispatched[0]["dispatched_at"]):
        reasons.append("artifact_predates_dispatch")
except Exception as exc:
    reasons.append("deliverable_missing_or_unreadable:" + type(exc).__name__)
if reasons:
    print("TASK_OK=0 reason=" + ",".join(reasons))
    raise SystemExit(1)
print(f"TASK_OK=1 job={job_id} scheduler_dispatch=observed executor_lease={dispatched[0]['lease_id']} contracts=4 junit_tests=4")
PY
