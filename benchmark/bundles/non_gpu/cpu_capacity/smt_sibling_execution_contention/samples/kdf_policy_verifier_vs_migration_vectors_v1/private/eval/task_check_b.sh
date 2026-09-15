#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "$B_JOB" "$B_PLACEMENT" "$B_ACCEPTANCE" "$B_OUTPUT_REAL" "$CONTROL_ROOT/work_contract.sha256" "$RESULT_ROOT/evidence/b_execution.json" "$B_INPUT_ROOT" "$B_PROGRAM" <<'PY'
import hashlib, json, pathlib, sys

def fail(reason): print(f"TASK_OK=0 reason={reason}"); raise SystemExit(1)
def digest(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
def merkle(values):
    nodes = [hashlib.sha256(b"leaf:" + value).digest() for value in values]
    while len(nodes) > 1:
        if len(nodes) % 2: nodes.append(nodes[-1])
        nodes = [hashlib.sha256(b"node:" + nodes[i] + nodes[i + 1]).digest() for i in range(0, len(nodes), 2)]
    return nodes[0].hex()
try:
    job_path, placement_path, acceptance_path, output, contract_path, observer_path, input_root, program = map(pathlib.Path, sys.argv[1:])
    required = [job_path, placement_path, acceptance_path, contract_path, observer_path, output / "verification_report.json", output / "migration_vectors.jsonl"]
    if not all(path.is_file() for path in required): fail("required_output_or_contract_missing")
    expected = {}
    for line in contract_path.read_text().splitlines(): value, name = line.split(maxsplit=1); expected[name] = value
    for path in (job_path, placement_path, acceptance_path, program):
        if expected.get(str(path)) != digest(path): fail("work_contract_changed")
    observer = json.loads(observer_path.read_text())
    exact_ticks = int(observer.get("max_exact_affinity_cpu_tick_delta", 0))
    if not observer.get("observed") or not observer.get("exact_affinity_observed") or exact_ticks < 20: fail("real_b_exact_affinity_execution_not_observed")
    if observer.get("program_sha256") != digest(program): fail("observed_program_identity_mismatch")
    job = json.loads(job_path.read_text()); acceptance = json.loads(acceptance_path.read_text()); placement = dict(line.split("=", 1) for line in placement_path.read_text().splitlines() if line)
    report = json.loads((output / "verification_report.json").read_text()); inputs = [json.loads(line) for line in (input_root / "migration_inputs.jsonl").read_text().splitlines() if line]; outputs = [json.loads(line) for line in (output / "migration_vectors.jsonl").read_text().splitlines() if line]
    b_cpu = int(placement["B_CPU"])
    if report.get("job_name") != job["job_name"] or report.get("placement_policy") != placement["PLACEMENT_POLICY_ID"]: fail("job_or_placement_mismatch")
    if report.get("assigned_cpu") != b_cpu or report.get("observed_affinity") != [b_cpu]: fail("wrong_b_affinity")
    if len(inputs) != job["vector_count"] or len(outputs) != len(inputs): fail("incomplete_vectors")
    derived = []
    for source, result in zip(inputs, outputs):
        if source["vector_id"] != result.get("vector_id"): fail("vector_order_mismatch")
        value = hashlib.pbkdf2_hmac("sha256", bytes.fromhex(source["secret_hex"]), bytes.fromhex(source["salt_hex"]), job["iterations"], dklen=job["dklen"])
        if value.hex() != result.get("derived_key_hex"): fail("derived_vector_invalid")
        derived.append(value)
    if report.get("merkle_root") != merkle(derived): fail("merkle_root_invalid")
    rate = float(report["vectors_per_second"]); minimum = float(acceptance["minimum_rate_per_second"])
    if rate < minimum or report.get("meets_acceptance") is not True: fail("vector_rate_below_frozen_acceptance")
    print(f"TASK_OK=1 vectors={len(outputs)} cpu={b_cpu} vectors_per_second={rate:.6f} minimum={minimum:.6f} exact_affinity_cpu_ticks={exact_ticks}")
except SystemExit: raise
except Exception as exc: fail("evidence_invalid_" + type(exc).__name__)
PY
