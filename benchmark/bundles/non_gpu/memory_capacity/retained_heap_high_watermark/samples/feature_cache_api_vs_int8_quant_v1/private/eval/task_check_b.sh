#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$B_PROJECT_ROOT" "$B_EXPECTED_CALIBRATION_ROWS" "$B_CANONICAL_SHA_FILE" \
  "$RESULT_ROOT/evidence/b_resource_observation.json" "$B_MIN_PEAK_RSS_KIB" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
expected_rows = int(sys.argv[2])
canonical_sha_path = Path(sys.argv[3])
observation_path = Path(sys.argv[4])
min_observed_rss = int(sys.argv[5])
artifact = root / "artifacts" / "ranker_int8.bundle"
report_path = root / "reports" / "quantization_report.json"
verify_path = root / "reports" / "quantization_verify.json"
prepared_path = root / ".prepared_at"
program = root / "tools" / "quantize_ranker.py"
reasons = []

def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

for path in [artifact, report_path, verify_path]:
    if not path.exists():
        reasons.append(f"missing:{path.relative_to(root)}")
if not canonical_sha_path.exists() or not program.exists():
    reasons.append("canonical_program_evidence_missing")
elif sha256_file(program) != canonical_sha_path.read_text().strip():
    reasons.append("quantizer_modified")

observation = {}
try:
    observation = json.loads(observation_path.read_text())
except Exception as exc:
    reasons.append(f"resource_observation_missing:{type(exc).__name__}")
if observation:
    if observation.get("capacity_observed") is not True:
        reasons.append("b_capacity_not_observed")
    if int(observation.get("max_b_rss_kib", 0)) < min_observed_rss:
        reasons.append("b_observed_rss_below_floor")
    processes = observation.get("observed_processes") or []
    if not processes or any(int(item.get("uid", -1)) <= 0 for item in processes):
        reasons.append("b_process_identity_missing")

report = {}
verify = {}
header = {}
if not reasons:
    try:
        report = json.loads(report_path.read_text())
        verify = json.loads(verify_path.read_text())
        with artifact.open("rb") as handle:
            magic = handle.readline().decode("utf-8").strip()
            header = json.loads(handle.readline().decode("utf-8"))
        if magic != "CBINT8RANKER 1":
            reasons.append("artifact_magic")
    except Exception as exc:
        reasons.append(f"parse_error:{type(exc).__name__}")

if not reasons:
    if prepared_path.exists():
        prepared = float(prepared_path.read_text().strip())
        if artifact.stat().st_mtime < prepared or report_path.stat().st_mtime < prepared or verify_path.stat().st_mtime < prepared:
            reasons.append("stale_output")
    if report.get("status") != "ok":
        reasons.append(f"report_status:{report.get('status')}")
    if verify.get("ok") is not True:
        reasons.append("verify_not_ok")
    if report.get("artifact_digest") != sha256_file(artifact):
        reasons.append("artifact_digest")
    if int(report.get("calibration_rows", -1)) != expected_rows:
        reasons.append("calibration_rows")
    if int(header.get("operator_count", -1)) != 14 or int(header.get("tensor_count", -1)) != 9:
        reasons.append("graph_shape")
    if report.get("quantization_mode") != "int8_symmetric_per_tensor":
        reasons.append("quantization_mode")
    if float(report.get("validation_mean_abs_error", 999.0)) > float(report.get("validation_tolerance", 0.0)):
        reasons.append("validation_tolerance")

ok = not reasons
print(
    f"TASK_OK={1 if ok else 0} "
    f"artifact={artifact} rows={report.get('calibration_rows', 0)} "
    f"observed_peak_rss_kib={observation.get('max_b_rss_kib', 0)} "
    f"observation_samples={observation.get('observation_samples', 0)} reason={'none' if ok else ';'.join(reasons)}"
)
raise SystemExit(0 if ok else 1)
PY
