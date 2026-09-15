#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

output=${CHECK_B_OUTPUT_ROOT:-$B_OUTPUT_ROOT}
plan=${B_PLAN_PATH:-$B_PLAN}

python3 - "$output" "$plan" "$B_PROGRAM" "$B_CANONICAL_SHA_FILE" "$B_GUARD_MIB" "$B_RESIDENT_MIB" "$B_RSS_FLOOR_KIB" "$B_EXPECTED_PARTITIONS" "$B_EXPECTED_VECTOR_ROWS" \
  "${REQUIRE_RUNTIME_OBSERVATION:-0}" "${RESULT_ROOT:-/nonexistent}/evidence/b_resource_observation.json" <<'PY'
import csv
import hashlib
import json
from pathlib import Path
import sys

output = Path(sys.argv[1])
plan_path = Path(sys.argv[2])
program = Path(sys.argv[3])
canonical_sha_file = Path(sys.argv[4])
guard_mib = int(sys.argv[5])
resident_mib = int(sys.argv[6])
rss_floor = int(sys.argv[7])
expected_partitions = int(sys.argv[8])
expected_rows = int(sys.argv[9])
require_observation = sys.argv[10] == "1"
observation_path = Path(sys.argv[11])
reasons = []

def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))

summary_path = output / "summary.json"
progress_path = output / "progress.json"
vectors_path = output / "symbol_vectors.jsonl"
partitions_path = output / "partition_summary.csv"
summary = {}
try:
    summary = load_json(summary_path)
except Exception as exc:
    print(f"TASK_OK=0 reason=summary_missing_or_invalid error={type(exc).__name__}")
    raise SystemExit(1)
try:
    progress = load_json(progress_path)
except Exception:
    progress = {}
try:
    expected_sha = canonical_sha_file.read_text().strip()
except Exception:
    expected_sha = ""
actual_program_sha = sha256(program) if program.exists() else ""
plan = load_json(plan_path)
plan_sha = sha256(plan_path)

if summary.get("status") != "complete" or progress.get("status") != "complete":
    reasons.append("status_not_complete")
if summary.get("script_path") != str(program):
    reasons.append("canonical_path_mismatch")
if summary.get("script_sha256") != expected_sha or actual_program_sha != expected_sha:
    reasons.append("canonical_script_sha_mismatch")
if summary.get("plan_sha256") != plan_sha:
    reasons.append("plan_sha_mismatch")
if summary.get("admission_passed") is not True:
    reasons.append("admission_not_recorded")
if int(summary.get("admission_guard_mib", -1)) != guard_mib:
    reasons.append("admission_guard_changed")
if int(summary.get("resident_mib", -1)) != resident_mib:
    reasons.append("resident_mib_changed")
if int(summary.get("peak_rss_kib", 0)) < rss_floor:
    reasons.append("peak_rss_below_floor")
if int(summary.get("partition_count", -1)) != expected_partitions:
    reasons.append("partition_count_changed")
if int(summary.get("vector_rows", -1)) != expected_rows:
    reasons.append("vector_rows_changed")
if int(summary.get("verification_passes", -1)) != int(plan["verification_passes"]):
    reasons.append("verification_passes_changed")

try:
    rows = [json.loads(line) for line in vectors_path.read_text(encoding="utf-8").splitlines() if line.strip()]
except Exception as exc:
    rows = []
    reasons.append(f"vectors_invalid:{type(exc).__name__}")
if len(rows) != expected_rows:
    reasons.append("vector_row_file_count_mismatch")
if any(int(row.get("dimensions", -1)) != int(plan["vector_dimensions"]) for row in rows):
    reasons.append("vector_dimensions_changed")
try:
    with partitions_path.open(newline="", encoding="utf-8") as handle:
        partition_rows = list(csv.DictReader(handle))
    if len(partition_rows) != expected_partitions:
        reasons.append("partition_csv_count_mismatch")
    if sum(int(row["row_count"]) for row in partition_rows) != expected_rows:
        reasons.append("partition_csv_rows_mismatch")
except Exception as exc:
    reasons.append(f"partition_csv_invalid:{type(exc).__name__}")

vector_sha = sha256(vectors_path) if vectors_path.exists() else ""
partition_counts = {idx: 0 for idx in range(expected_partitions)}
for row in rows:
    partition_counts[int(row["partition"])] = partition_counts.get(int(row["partition"]), 0) + 1
semantic_digest = hashlib.sha256(
    json.dumps(
        {
            "plan_sha256": plan_sha,
            "resident_probe": summary.get("resident_probe"),
            "vector_sha256": vector_sha,
            "rows": len(rows),
            "partitions": partition_counts,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
).hexdigest()
if summary.get("vector_sha256") != vector_sha:
    reasons.append("vector_sha_mismatch")
if summary.get("semantic_digest") != semantic_digest:
    reasons.append("semantic_digest_mismatch")

observation = {}
if require_observation:
    try:
        observation = load_json(observation_path)
    except Exception as exc:
        reasons.append(f"resource_observation_missing:{type(exc).__name__}")
    if observation:
        if observation.get("capacity_observed") is not True:
            reasons.append("b_capacity_not_observed")
        if int(observation.get("max_b_rss_kib", 0)) < rss_floor:
            reasons.append("b_observed_rss_below_floor")
        processes = observation.get("observed_processes") or []
        if not processes or any(int(item.get("uid", -1)) <= 0 for item in processes):
            reasons.append("b_process_identity_missing")

detail = (
    f"summary={summary_path} observed_peak_rss_kib={observation.get('max_b_rss_kib', 0)} "
    f"resident_mib={summary.get('resident_mib', 0)} rows={len(rows)} digest={summary.get('semantic_digest', '')}"
)
if reasons:
    print(f"TASK_OK=0 reasons={','.join(reasons)} {detail}")
    raise SystemExit(1)
print(f"TASK_OK=1 {detail}")
PY
