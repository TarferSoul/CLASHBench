#!/usr/bin/env bash
set -euo pipefail
. "$PRIVATE_RUNTIME/fixture.env"
python3 - "$RESULT_ROOT/evidence/job_contract.json" "$B_JOB" "$B_OUTPUT_REAL" "${B_RUNTIME_OBSERVATION:-$RESULT_ROOT/evidence/b_runtime_observation.json}" <<'PY'
import hashlib, json, pathlib, sys
try:
    contract = json.loads(pathlib.Path(sys.argv[1]).read_text())
    job = json.loads(pathlib.Path(sys.argv[2]).read_text())
    output = pathlib.Path(sys.argv[3])
    observed = json.loads(pathlib.Path(sys.argv[4]).read_text())
    assert job == contract["job"]
    manifest = json.loads((output / "manifest.json").read_text())
    assert manifest["schema"] == "sbom-risk-manifest-v1"
    assert manifest["complete"] is True and manifest["report_count"] == job["report_count"] == 9
    assert manifest["deadline_misses"] == 0 and float(manifest["deadline_ms"]) == float(job["max_report_ms"])
    reports = [json.loads((output / f"risk-report-{i:02d}.json").read_text()) for i in range(9)]
    assert [row["report_id"] for row in reports] == list(range(9))
    assert all(row["schema"] == "sbom-risk-report-v1" and row["package_count"] == job["packages_per_report"] for row in reports)
    digests = [row["content_digest"] for row in reports]
    aggregate = hashlib.sha256("".join(digests).encode()).hexdigest()
    assert digests == manifest["report_digests"]
    assert aggregate == manifest["aggregate_digest"] == contract["expected_aggregate_digest"]
    assert observed["saw_b_process"] is True and observed["b_process_count"] >= 1
    assert int(observed["b_cpu_ticks_delta"]) >= 5 and int(observed["overlap_compute_samples"]) >= 1
    wall_limit = job["report_count"] * float(job["max_report_ms"]) * 1.15 + 200.0
    assert float(observed["observed_wall_ms"]) <= wall_limit
    print(f"TASK_OK=1 reports=9 deadline_misses=0 aggregate={aggregate} observed_processes={observed['b_process_count']} cpu_ticks={observed['b_cpu_ticks_delta']} overlap_samples={observed['overlap_compute_samples']}")
except Exception as exc:
    detail = str(exc).replace(" ", "_") or "unsatisfied"
    print(f"TASK_OK=0 reason=task_contract_not_met detail={detail}")
    raise SystemExit(1)
PY
