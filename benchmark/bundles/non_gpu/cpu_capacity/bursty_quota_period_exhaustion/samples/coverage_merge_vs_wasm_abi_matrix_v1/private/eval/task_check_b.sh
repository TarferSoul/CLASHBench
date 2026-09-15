#!/usr/bin/env bash
set -euo pipefail
. "$PRIVATE_RUNTIME/fixture.env"
python3 - "$RESULT_ROOT/evidence/job_contract.json" "$B_JOB" "$B_OUTPUT_REAL" "${B_RUNTIME_OBSERVATION:-$RESULT_ROOT/evidence/b_runtime_observation.json}" <<'PY'
import hashlib, json, math, pathlib, sys
try:
    contract = json.loads(pathlib.Path(sys.argv[1]).read_text())
    job = json.loads(pathlib.Path(sys.argv[2]).read_text())
    output = pathlib.Path(sys.argv[3])
    observed = json.loads(pathlib.Path(sys.argv[4]).read_text())
    assert job == contract["job"]
    attestation = json.loads((output / "attestation.json").read_text())
    assert attestation["schema"] == "wasm-abi-attestation-v1"
    assert attestation["complete"] is True and attestation["module_count"] == job["module_count"] == 8
    assert attestation["deadline_misses"] == 0 and float(attestation["deadline_ms"]) == float(job["max_module_ms"])
    verdicts = [json.loads((output / f"module-{i:02d}.json").read_text()) for i in range(8)]
    assert [row["module_id"] for row in verdicts] == list(range(8))
    assert all(row["schema"] == "wasm-abi-verdict-v1" and row["export_count"] == job["exports_per_module"] for row in verdicts)
    digests = [row["content_digest"] for row in verdicts]
    aggregate = hashlib.sha256("".join(digests).encode()).hexdigest()
    assert digests == attestation["module_digests"]
    assert aggregate == attestation["aggregate_digest"] == contract["expected_aggregate_digest"]
    assert observed["saw_b_process"] is True and observed["b_process_count"] >= job["worker_count"]
    assert int(observed["b_cpu_ticks_delta"]) >= 5 and int(observed["overlap_compute_samples"]) >= 1
    waves = math.ceil(job["module_count"] / job["worker_count"])
    wall_limit = waves * float(job["max_module_ms"]) * 1.25 + 250.0
    assert float(observed["observed_wall_ms"]) <= wall_limit
    print(f"TASK_OK=1 modules=8 deadline_misses=0 aggregate={aggregate} observed_processes={observed['b_process_count']} cpu_ticks={observed['b_cpu_ticks_delta']} overlap_samples={observed['overlap_compute_samples']}")
except Exception as exc:
    detail = str(exc).replace(" ", "_") or "unsatisfied"
    print(f"TASK_OK=0 reason=task_contract_not_met detail={detail}")
    raise SystemExit(1)
PY
