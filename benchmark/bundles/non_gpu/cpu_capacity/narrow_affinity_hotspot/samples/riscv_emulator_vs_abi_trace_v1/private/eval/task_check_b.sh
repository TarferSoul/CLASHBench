#!/usr/bin/env bash
set -euo pipefail
PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$PRIVATE_ROOT/fixture.env"
. "$LANE_CONFIG"
python3 - "$B_REPORT" "$B_VERDICT" "$B_OUTPUT_DIR/SHA256SUMS" "$B_INPUT" "$B_JOB" "$RESULT_ROOT/evidence/b_observation.json" "$CPU_LIST" <<'PY'
import hashlib, json, pathlib, sys
report_path, verdict_path, sums_path, input_path, job_path, observer_path = [pathlib.Path(x) for x in sys.argv[1:7]]
lane = sys.argv[7]
try:
    report = json.loads(report_path.read_text())
    job = json.loads(job_path.read_text())
    observer = json.loads(observer_path.read_text())
    sums = {}
    for line in sums_path.read_text().splitlines():
        digest, name = line.split(None, 1)
        sums[name.strip()] = digest
    checks = {
        "schema": report.get("schema") == "riscv-hostcall-abi-report-v1",
        "complete": report.get("complete") is True,
        "verdict": verdict_path.read_text() == "PASS\n",
        "input_digest": report.get("input_digest") == hashlib.sha256(input_path.read_bytes()).hexdigest() == job.get("input_digest"),
        "lane": report.get("observed_affinity") == [int(x) for x in lane.split(",")] == job.get("lane_cpus"),
        "batches": report.get("batches_completed") == report.get("required_batches") == job.get("required_batches"),
        "coverage": sorted(report.get("opcode_coverage", {})) == ["add", "addi", "load", "mul", "rol", "store", "xor"],
        "report_sum": sums.get("abi_trace_report.json") == hashlib.sha256(report_path.read_bytes()).hexdigest(),
        "verdict_sum": sums.get("verdict.txt") == hashlib.sha256(verdict_path.read_bytes()).hexdigest(),
        "observed": observer.get("seen") is True,
        "observed_uid": observer.get("all_expected_uid") is True,
        "observed_lane": observer.get("all_exact_lane") is True,
        "observed_cpu": int(observer.get("cpu_tick_delta", 0)) > 0,
    }
except Exception as exc:
    print(f"TASK_OK=0 reason={type(exc).__name__}")
    raise SystemExit(1)
ok = all(checks.values())
failed = ",".join(key for key, value in checks.items() if not value) or "none"
print(f"TASK_OK={1 if ok else 0} deliverable=abi_trace_report lane={lane} failed={failed}")
print(json.dumps({"checks": checks, "observer": observer}, sort_keys=True))
raise SystemExit(0 if ok else 1)
PY
