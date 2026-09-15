#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

python3 - "$B_OUTPUT_DIR" "$B_RESIDENT_MIB" "$B_VERIFICATION_PASSES" "$B_PARTITIONS" "$B_MIN_PEAK_RSS_KIB" "$B_INSTALLED_PROGRAM" "$B_PROGRAM" "$B_ADMISSION_GUARD_MIB" <<'PY'
import csv
import hashlib
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
resident_mib = int(sys.argv[2])
passes = int(sys.argv[3])
partitions = int(sys.argv[4])
min_peak = int(sys.argv[5])
canonical_program = pathlib.Path(sys.argv[6])
expected_work_program = sys.argv[7]
guard_mib = int(sys.argv[8])
summary_path = out / "embedding_matrix_summary.json"
partition_path = out / "partition_report.csv"
progress_path = out / "progress.json"
reasons = []

def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

try:
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
except Exception as exc:
    progress_state = "missing"
    if progress_path.exists():
        try:
            progress_state = json.loads(progress_path.read_text(encoding="utf-8")).get("state", "unknown")
        except Exception:
            progress_state = "unparseable"
    print(f"TASK_OK=0 reason=missing_or_invalid_summary progress_state={progress_state} error={type(exc).__name__}")
    raise SystemExit(0)

if summary.get("complete") is not True:
    reasons.append("not_complete")
if summary.get("plan_id") != "code-intel-dependency-graph-2026-07":
    reasons.append("wrong_plan")
if int(summary.get("resident_mib", 0)) != resident_mib:
    reasons.append("resident_mib_changed")
if int(summary.get("passes_completed", 0)) != passes:
    reasons.append("passes_incomplete")
if int(summary.get("partitions", 0)) != partitions:
    reasons.append("partition_count_changed")
if int(summary.get("peak_rss_kib", 0)) < min_peak:
    reasons.append("peak_rss_too_low")
if len(str(summary.get("matrix_digest", ""))) != 64:
    reasons.append("missing_digest")
builder = summary.get("builder") if isinstance(summary.get("builder"), dict) else {}
try:
    canonical_sha = file_sha256(canonical_program)
except Exception:
    canonical_sha = ""
if builder.get("path") != expected_work_program:
    reasons.append("wrong_builder_path")
if builder.get("sha256") != canonical_sha:
    reasons.append("builder_sha_mismatch")
admission = summary.get("admission") if isinstance(summary.get("admission"), dict) else {}
if admission.get("state") != "admission_passed":
    reasons.append("admission_not_recorded")
if int(admission.get("guard_bytes", -1)) != guard_mib * 1024 * 1024:
    reasons.append("admission_guard_changed")

try:
    with partition_path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
except Exception:
    rows = []
    reasons.append("partition_report_missing")
expected_rows = partitions * passes
if len(rows) != expected_rows:
    reasons.append("partition_rows_mismatch")
try:
    progress = json.loads(progress_path.read_text(encoding="utf-8"))
except Exception:
    progress = {}
    reasons.append("progress_missing")
if progress.get("state") != "complete":
    reasons.append("progress_not_complete")
if progress.get("digest") != summary.get("matrix_digest"):
    reasons.append("progress_digest_mismatch")

ok = not reasons
print(
    f"TASK_OK={1 if ok else 0} resident_mib={summary.get('resident_mib', 0)} "
    f"passes_completed={summary.get('passes_completed', 0)} peak_rss_kib={summary.get('peak_rss_kib', 0)} "
    f"partition_rows={len(rows)} digest={summary.get('matrix_digest', '')} "
    f"reasons={','.join(reasons) if reasons else 'none'}"
)
PY
