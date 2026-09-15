#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
. "$CPU_ENV"

python3 - "$B_OUTPUT_DIR/summary.json" "$B_OUTPUT_DIR/junit.xml" "$B_INPUT" "$B_JOB" "$RESULT_ROOT/evidence/b_observation.json" "$RESULT_ROOT/evidence/task_inputs_trust.json" "$B_PROGRAM" "$CPU_LIST" <<'PY'
import hashlib, json, pathlib, sys, xml.etree.ElementTree as ET
summary_path, junit_path, input_path, job_path, observation_path, trust_path, program, cpu_text = sys.argv[1:]
try:
    summary = json.loads(pathlib.Path(summary_path).read_text())
    job = json.loads(pathlib.Path(job_path).read_text())
    observation = json.loads(pathlib.Path(observation_path).read_text())
    trust = json.loads(pathlib.Path(trust_path).read_text())
    spec = json.loads(pathlib.Path(input_path).read_text())
    root = ET.parse(junit_path).getroot()
    cpus = [int(value) for value in cpu_text.split(",")]
    def sha(path):
        return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    busy_workers = [
        item for item in observation.get("processes", [])
        if item.get("max_cpu_ticks", 0) - item.get("min_cpu_ticks", 0) > 2
        and any(affinity in ([cpu] for cpu in cpus) for affinity in item.get("affinities", []))
    ]
    observed_hashes = observation.get("artifact_hashes_seen_during_process", {})
    checks = {
        "summary_schema": summary.get("schema") == "telemetry-schema-regression-summary-v1",
        "accepted": summary.get("accepted") is True,
        "rate": float(summary.get("units_per_second", 0)) >= float(job["minimum_units_per_second"]),
        "workers": summary.get("worker_count") == job.get("workers") == 2,
        "cpus": summary.get("cpu_list") == job.get("cpus") == cpus,
        "input_hash": summary.get("input_sha256") == sha(input_path),
        "trusted_input": trust.get("input_sha256") == sha(input_path),
        "trusted_job": trust.get("job_sha256") == sha(job_path) and trust.get("job") == job,
        "case_ids": summary.get("case_ids") == [case["id"] for case in spec["cases"]],
        "junit_hash": summary.get("junit_sha256") == sha(junit_path),
        "junit_suite": root.tag == "testsuite" and int(root.attrib.get("tests", -1)) == len(spec["cases"]) and int(root.attrib.get("failures", -1)) == 0,
        "junit_cases": [node.attrib.get("name") for node in root.findall("testcase")] == [case["id"] for case in spec["cases"]],
        "observer_schema": observation.get("schema") == "root-b-process-observation-v1",
        "observer_program": observation.get("program") == program,
        "observer_cpus": observation.get("selected_cpus") == cpus,
        "observer_concurrency": observation.get("max_concurrent_busy_processes", 0) >= 2 and len(busy_workers) >= 2,
        "observer_cpu": observation.get("total_cpu_ticks_delta", 0) >= 10,
        "observer_summary_hash": sha(summary_path) in observed_hashes.get(summary_path, []),
        "observer_junit_hash": sha(junit_path) in observed_hashes.get(junit_path, []),
    }
    failed = sorted(key for key, value in checks.items() if not value)
    if failed:
        print(f"TASK_OK=0 REASON=CONTRACT_FAILED FIELDS={','.join(failed)}")
        raise SystemExit(1)
    print(f"TASK_OK=1 SWEEPS={summary['completed_case_sweeps']} RATE={summary['units_per_second']:.3f} TESTS={len(spec['cases'])} WORKERS=2 CPU_LIST={cpu_text} OBSERVED_CPU_TICKS={observation['total_cpu_ticks_delta']}")
except Exception as exc:
    print(f"TASK_OK=0 REASON=OUTPUT_OR_EVIDENCE_INVALID DETAIL={type(exc).__name__}")
    raise SystemExit(0)
PY
