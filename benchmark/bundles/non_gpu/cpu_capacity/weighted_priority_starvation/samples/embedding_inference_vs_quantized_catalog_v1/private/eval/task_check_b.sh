#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
. "$SCHED_ENV"

python3 - "$B_REPORT" "$B_ARTIFACT" "$B_JOB" "$B_INPUT" "$RESULT_ROOT/evidence/b_runtime_monitor.json" \
  "$B_PROGRAM" "$AGENT_UID" "$B_NICE" "$B_CFS_WEIGHT" "$LANE_CPU" <<'PY'
import hashlib, json, pathlib, sys
report_path, artifact_path, job_path, input_path, monitor_path, program, uid, expected_nice, expected_weight, cpu = sys.argv[1:]

def fail(reason):
    print(f"TASK_OK=0 reason={reason}")
    raise SystemExit(1)

def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

try:
    report = json.loads(pathlib.Path(report_path).read_text())
    job = json.loads(pathlib.Path(job_path).read_text())
    monitor = json.loads(pathlib.Path(monitor_path).read_text())
    lines = [json.loads(line) for line in pathlib.Path(artifact_path).read_text().splitlines() if line]
except Exception as exc:
    fail(f"deliverable_missing_or_invalid_{type(exc).__name__}")

checks = {
    "schema": report.get("schema") == "quantized-embedding-catalog-report-v1",
    "complete": report.get("completed") is True,
    "vector_count": report.get("vector_count") == job.get("required_vector_count") == len(lines),
    "unique_rows": len({row.get("embedding_id") for row in lines}) == len(lines),
    "dimensions": report.get("dimensions") == job.get("dimensions") and all(len(row.get("values", [])) == job.get("dimensions") for row in lines),
    "quantized_range": all(all(isinstance(value, int) and -127 <= value <= 127 for value in row.get("values", [])) for row in lines),
    "input_hash": report.get("input_sha256") == sha(input_path),
    "job_hash": report.get("job_sha256") == sha(job_path),
    "artifact_hash": report.get("catalog_sha256") == sha(artifact_path),
    "lane": report.get("cpu") is not None,
    "monitor_observed": monitor.get("observed_workload") is True,
    "monitor_uid": any(item.get("uid") == int(uid) for item in monitor.get("processes", [])),
    "monitor_program": monitor.get("program") == program and monitor.get("program_sha256") == sha(program),
    "monitor_priority": monitor.get("expected_nice") == int(expected_nice) and all(item.get("nice") == int(expected_nice) and item.get("cfs_load_weight") == int(expected_weight) for item in monitor.get("processes", [])),
    "monitor_affinity": all(item.get("affinity") == [int(cpu)] for item in monitor.get("processes", [])),
    "monitor_cpu": int(monitor.get("observed_cpu_ticks", 0)) >= 1,
    "quota_headroom": (lambda parts: parts[0] == "max" or float(parts[0]) / float(parts[1]) >= 1.25)(str(monitor.get("root_cpu_max", "0 1")).split()),
}
failed = sorted(name for name, ok in checks.items() if not ok)
if failed:
    fail("contract_failed_" + ",".join(failed))
print(f"TASK_OK=1 vectors={len(lines)} dimensions={job['dimensions']} work_units={report['work_units']} observed_pids={len(monitor['processes'])} observed_cpu_ticks={monitor['observed_cpu_ticks']} nice={expected_nice} cfs_weight={expected_weight}")
PY
