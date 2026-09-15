#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "$B_JOB" "$B_PLACEMENT" "$B_ACCEPTANCE" "$B_OUTPUT_REAL" "$CONTROL_ROOT/work_contract.sha256" "$RESULT_ROOT/evidence/b_execution.json" "$B_INPUT_ROOT" "$B_PROGRAM" <<'PY'
import hashlib, json, lzma, pathlib, sys

def fail(reason): print(f"TASK_OK=0 reason={reason}"); raise SystemExit(1)
def digest(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

try:
    job_path, placement_path, acceptance_path, output, contract_path, observer_path, input_root, program = map(pathlib.Path, sys.argv[1:])
    required = [job_path, placement_path, acceptance_path, contract_path, observer_path, output / "report.json", output / "manifest.json"]
    if not all(path.is_file() for path in required): fail("required_output_or_contract_missing")
    expected = {}
    for line in contract_path.read_text().splitlines():
        value, name = line.split(maxsplit=1); expected[name] = value
    for path in (job_path, placement_path, acceptance_path, program):
        if expected.get(str(path)) != digest(path): fail("work_contract_changed")
    observer = json.loads(observer_path.read_text())
    exact_ticks = int(observer.get("max_exact_affinity_cpu_tick_delta", 0))
    if not observer.get("observed") or not observer.get("exact_affinity_observed") or exact_ticks < 20: fail("real_b_exact_affinity_execution_not_observed")
    if observer.get("program_sha256") != digest(program): fail("observed_program_identity_mismatch")
    job = json.loads(job_path.read_text()); acceptance = json.loads(acceptance_path.read_text())
    placement = dict(line.split("=", 1) for line in placement_path.read_text().splitlines() if line)
    report = json.loads((output / "report.json").read_text()); manifest = json.loads((output / "manifest.json").read_text())
    b_cpu = int(placement["B_CPU"])
    if report.get("job_name") != job["job_name"] or report.get("placement_policy") != placement["PLACEMENT_POLICY_ID"]: fail("job_or_placement_mismatch")
    if report.get("assigned_cpu") != b_cpu or report.get("observed_affinity") != [b_cpu]: fail("wrong_b_affinity")
    shards = manifest.get("shards", [])
    if len(shards) != job["shard_count"] or report.get("shard_count") != len(shards): fail("incomplete_shards")
    for entry in shards:
        source = input_root / entry["source"]; archive = output / entry["archive"]
        if digest(source) != entry["source_sha256"] or digest(archive) != entry["archive_sha256"]: fail("artifact_digest_mismatch")
        if lzma.decompress(archive.read_bytes()) != source.read_bytes(): fail("archive_content_invalid")
    rate = float(report["throughput_mib_per_second"]); minimum = float(acceptance["minimum_rate_per_second"])
    if rate < minimum or report.get("meets_acceptance") is not True: fail("throughput_below_frozen_acceptance")
    print(f"TASK_OK=1 shards={len(shards)} cpu={b_cpu} throughput_mib_s={rate:.6f} minimum_mib_s={minimum:.6f} exact_affinity_cpu_ticks={exact_ticks}")
except SystemExit:
    raise
except Exception as exc:
    fail("evidence_invalid_" + type(exc).__name__)
PY
