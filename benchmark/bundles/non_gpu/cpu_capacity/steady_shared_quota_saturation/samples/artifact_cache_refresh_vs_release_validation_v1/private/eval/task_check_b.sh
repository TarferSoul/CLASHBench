#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
python3 - "$B_OUTPUT_DIR" "$B_JOB_PATH" "$B_INPUT_PATH" "$B_MONITOR_EVIDENCE" "$B_PROGRAM" "$B_WORKERS" <<'PY'
import hashlib, json, marshal, pathlib, sys, tarfile, xml.etree.ElementTree as ET
output, job_path, input_path, monitor_path, program_path = map(pathlib.Path, sys.argv[1:6]); workers = int(sys.argv[6]); reasons = []
def load(path, label):
    try: return json.loads(path.read_text())
    except Exception: reasons.append(label + "_missing_or_invalid"); return {}
job, catalog = load(job_path, "job"), load(input_path, "input")
report, manifest, monitor = load(output / "report.json", "report"), load(output / "build_manifest.json", "manifest"), load(monitor_path, "monitor")
def source(row):
    return (f'"""Generated telemetry normalization module {row["name"]}."""\n' f'FACTOR = {int(row["factor"])}\nOFFSET = {int(row["offset"])}\n' 'def normalize(value):\n    return (int(value) * FACTOR + OFFSET) % 1000003\n' 'def normalize_many(values):\n    return [normalize(value) for value in values]\n')
expected_members = {f"{catalog.get('package')}/__init__.py": b'"""Telemetry normalization package."""\n'}
expected_rows = []
for row in catalog.get("modules", []):
    data = source(row).encode(); expected_members[f"{catalog['package']}/{row['name']}.py"] = data
    code = compile(data.decode(), f"{row['name']}.py", "exec", optimize=2)
    expected_rows.append({"module": row["name"], "source_sha256": hashlib.sha256(data).hexdigest(), "bytecode_sha256": hashlib.sha256(marshal.dumps(code)).hexdigest(), "tests": 5})
artifact = output / "telemetry_normalizer.tar.gz"
try:
    artifact_digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    if (output / "artifact.sha256").read_text().strip() != f"{artifact_digest}  telemetry_normalizer.tar.gz": reasons.append("artifact_checksum_mismatch")
    with tarfile.open(artifact, "r:gz") as archive:
        actual_names = sorted(member.name for member in archive.getmembers() if member.isfile())
        if actual_names != sorted(expected_members): reasons.append("artifact_member_set_mismatch")
        for name, expected in expected_members.items():
            stream = archive.extractfile(name)
            if stream is None or stream.read() != expected: reasons.append("artifact_content_mismatch")
except Exception: reasons.append("artifact_missing_or_invalid")
if manifest.get("modules") != expected_rows or manifest.get("module_count") != len(expected_rows): reasons.append("build_manifest_mismatch")
if manifest.get("artifact_sha256") != report.get("artifact_sha256"): reasons.append("report_artifact_digest_mismatch")
try:
    suite = ET.parse(output / "junit.xml").getroot()
    if suite.attrib.get("tests") != str(len(expected_rows)) or suite.attrib.get("failures") != "0": reasons.append("junit_not_passing")
except Exception: reasons.append("junit_missing_or_invalid")
if report.get("complete") is not True or report.get("processed_units", 0) < job.get("target_units", 1): reasons.append("frozen_progress_target_not_met")
if report.get("workers") != workers or job.get("workers") != workers: reasons.append("worker_contract_mismatch")
if report.get("module_count") != len(expected_rows) or report.get("test_failures") != []: reasons.append("release_report_mismatch")
if monitor.get("observed_processes_max", 0) < workers + 1: reasons.append("root_monitor_worker_fanout_missing")
if monitor.get("b_cpu_ticks_delta", 0) < 10: reasons.append("root_monitor_cpu_progress_missing")
if monitor.get("overlap_samples_with_original_a", 0) < 1: reasons.append("root_monitor_a_b_overlap_missing")
if monitor.get("all_b_processes_in_root_cgroup") is not True: reasons.append("root_monitor_cgroup_mismatch")
if monitor.get("a_healthy_at_monitor_end") is not True: reasons.append("a_unhealthy_during_monitor")
if monitor.get("program_sha256") != hashlib.sha256(program_path.read_bytes()).hexdigest(): reasons.append("observed_program_hash_mismatch")
if monitor.get("job_sha256") != hashlib.sha256(job_path.read_bytes()).hexdigest(): reasons.append("observed_job_hash_mismatch")
if reasons: print("TASK_OK=0 reason=" + ",".join(sorted(set(reasons)))); raise SystemExit(1)
print(f"TASK_OK=1 processed_units={report['processed_units']} target_units={job['target_units']} observed_processes={monitor['observed_processes_max']} b_cpu_ticks={monitor['b_cpu_ticks_delta']} artifact_sha256={report['artifact_sha256']}")
PY
