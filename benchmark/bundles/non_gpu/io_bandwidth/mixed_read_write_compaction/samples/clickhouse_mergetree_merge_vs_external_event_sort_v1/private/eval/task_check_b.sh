#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

python3 - "$B_SUMMARY" "$B_INDEX" "$B_SCRATCH" "$B_PLAN" <<'PY'
import hashlib, json, os, pathlib, sys

summary_path, index_path, scratch_path, plan_path = sys.argv[1:]
required = {
    "input_partition_count",
    "row_count",
    "min_timestamp",
    "max_timestamp",
    "sorted_run_count",
    "checksum",
    "validation_ok",
    "objective_seconds",
    "elapsed_seconds",
}

def fail(reason):
    print(f"TASK_OK=0 reason={reason}")
    raise SystemExit(1)

try:
    summary = json.loads(pathlib.Path(summary_path).read_text())
except Exception:
    fail("missing_or_invalid_summary")
if not required.issubset(summary):
    fail("missing_required_fields")
if not pathlib.Path(index_path).is_file():
    fail("missing_final_index")
try:
    plan = json.loads(pathlib.Path(plan_path).read_text())
except Exception:
    plan = {}
if summary.get("scratch_path") != scratch_path:
    fail("wrong_scratch_path")
try:
    if os.stat(pathlib.Path(index_path).parent).st_dev != os.stat(pathlib.Path(scratch_path)).st_dev:
        fail("output_not_on_scratch_device")
except OSError:
    fail("device_check_failed")
digest = hashlib.sha256()
rows = 0
last = None
sorted_ok = True
with pathlib.Path(index_path).open("r", encoding="utf-8") as handle:
    for line in handle:
        digest.update(line.encode())
        item = json.loads(line)
        key = (item["timestamp"], item["event_id"])
        if last is not None and key < last:
            sorted_ok = False
        last = key
        rows += 1
if rows != int(summary.get("row_count") or -1):
    fail("row_count_mismatch")
if digest.hexdigest() != summary.get("checksum"):
    fail("checksum_mismatch")
if not sorted_ok or summary.get("validation_ok") is not True:
    fail("validation_failed")
if plan.get("expected_row_count") and rows != int(plan["expected_row_count"]):
    fail("plan_row_count_mismatch")
objective = float(summary.get("objective_seconds") or 0)
elapsed = float(summary.get("elapsed_seconds") or 0)
if objective > 0 and elapsed > objective:
    print(f"TASK_OK=0 reason=late elapsed_seconds={elapsed:.3f} objective_seconds={objective:.3f} rows={rows}")
    raise SystemExit(1)
print(f"TASK_OK=1 rows={rows} elapsed_seconds={elapsed:.3f} objective_seconds={objective:.3f} sorted_run_count={summary.get('sorted_run_count')}")
PY
