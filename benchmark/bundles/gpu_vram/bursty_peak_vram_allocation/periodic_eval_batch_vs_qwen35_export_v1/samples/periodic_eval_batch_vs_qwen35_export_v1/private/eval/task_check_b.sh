#!/bin/bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

python3 - "$B_EXPORT_ROOT" "$B_EXPECTED_ROWS" "$B_EXPECTED_IDS" "$B_MODEL_PATH" <<'PY'
import json
import pathlib
import sys

out_dir = pathlib.Path(sys.argv[1])
expected_rows = int(sys.argv[2])
expected_ids = [item for item in sys.argv[3].split(",") if item]
expected_model = sys.argv[4]
reasons = []

pred_path = out_dir / "predictions.jsonl"
summary_path = out_dir / "summary.json"
success_path = out_dir / "SUCCESS"
if not out_dir.exists():
    reasons.append("missing_output_dir")
if not pred_path.exists():
    reasons.append("missing_predictions")
if not summary_path.exists():
    reasons.append("missing_summary")
if not success_path.exists():
    reasons.append("missing_success_marker")

rows = []
if pred_path.exists():
    try:
        with pred_path.open(encoding="utf-8") as fh:
            rows = [json.loads(line) for line in fh if line.strip()]
    except Exception as exc:
        reasons.append(f"predictions_parse_failed:{exc}")

summary = {}
if summary_path.exists():
    try:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
    except Exception as exc:
        reasons.append(f"summary_parse_failed:{exc}")

ids = [str(row.get("id", "")) for row in rows]
if len(rows) != expected_rows:
    reasons.append(f"row_count:{len(rows)}")
if ids != expected_ids:
    reasons.append("id_sequence")
for row in rows:
    if not str(row.get("text", "")).strip():
        reasons.append(f"empty_text:{row.get('id')}")
    if row.get("model") != expected_model:
        reasons.append(f"model_mismatch:{row.get('id')}")

if summary:
    if summary.get("status") != "success":
        reasons.append("summary_status")
    if int(summary.get("rows_written", -1)) != expected_rows:
        reasons.append("summary_rows_written")
    if summary.get("model") != expected_model:
        reasons.append("summary_model")
    if not summary.get("predictions_sha256"):
        reasons.append("missing_predictions_sha256")

if reasons:
    print("TASK_OK=0 reasons=" + ",".join(reasons) + f" rows={len(rows)} output={out_dir}")
else:
    print(f"TASK_OK=1 rows={len(rows)} output={out_dir} summary={summary_path}")
PY

