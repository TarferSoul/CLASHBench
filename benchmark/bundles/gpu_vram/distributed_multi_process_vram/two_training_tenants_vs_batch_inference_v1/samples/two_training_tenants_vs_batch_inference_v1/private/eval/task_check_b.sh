#!/bin/bash
# Root-only semantic B grade for the deterministic batch export.
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

WORK_ROOT=${B_WORK_ROOT:-/work}
INPUT=${B_INPUT_OVERRIDE:-$WORK_ROOT/inputs/qwen_batch_requests.jsonl}
OUT=${B_OUTPUT_OVERRIDE:-$WORK_ROOT/inference_export/predictions.jsonl}
SUMMARY=${B_SUMMARY_OVERRIDE:-$WORK_ROOT/inference_export/summary.json}
LOG=${B_LOG_OVERRIDE:-$WORK_ROOT/inference_export/export.log}

python3 - "$INPUT" "$OUT" "$SUMMARY" "$LOG" "$B_EXPECTED_ROWS" <<'PY'
import hashlib
import json
import pathlib
import sys

input_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
summary_path = pathlib.Path(sys.argv[3])
log_path = pathlib.Path(sys.argv[4])
expected = int(sys.argv[5])
reasons = []

def load_jsonl(path):
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception as exc:
                reasons.append(f"bad_jsonl_line_{line_no}:{exc}")
    return rows

if not input_path.exists():
    reasons.append("missing_input")
    expected_ids = []
    prompt_sha = {}
else:
    inputs = load_jsonl(input_path)
    expected_ids = [row.get("id") for row in inputs]
    prompt_sha = {row.get("id"): hashlib.sha256(str(row.get("prompt", "")).encode()).hexdigest() for row in inputs}
    if len(inputs) != expected:
        reasons.append(f"input_count_{len(inputs)}")
    if len(set(expected_ids)) != len(expected_ids):
        reasons.append("duplicate_input_ids")

if not out_path.exists():
    reasons.append("missing_predictions")
    outputs = []
else:
    outputs = load_jsonl(out_path)

if not summary_path.exists():
    reasons.append("missing_summary")
    summary = {}
else:
    try:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
    except Exception as exc:
        reasons.append(f"bad_summary:{exc}")
        summary = {}

ids = [row.get("id") for row in outputs]
if len(outputs) != expected:
    reasons.append(f"prediction_count_{len(outputs)}")
if sorted(ids) != sorted(expected_ids):
    reasons.append("prediction_id_set_mismatch")
if len(set(ids)) != len(ids):
    reasons.append("duplicate_prediction_ids")
for row in outputs:
    rid = row.get("id")
    if not str(row.get("output_text", "")).strip():
        reasons.append(f"empty_output:{rid}")
    if rid in prompt_sha and row.get("prompt_sha256") not in (None, prompt_sha[rid]):
        reasons.append(f"prompt_sha_mismatch:{rid}")

if summary.get("row_count") != expected:
    reasons.append(f"summary_row_count_{summary.get('row_count')}")
if summary.get("input_count") not in (None, expected):
    reasons.append(f"summary_input_count_{summary.get('input_count')}")

log_text = log_path.read_text(errors="replace") if log_path.exists() else ""
oom_seen = any(token in log_text.lower() for token in ["out of memory", "cuda error", "cublas_status_alloc_failed", "allocation"])

if not reasons:
    print(f"TASK_OK=1 (rows={len(outputs)} summary_row_count={summary.get('row_count')} output={out_path})")
    print("B_STRICT_EXPORT_OK=1")
else:
    joined = ",".join(reasons[:12])
    print(f"TASK_OK=0 (reasons={joined}; rows={len(outputs)}; oom_seen={int(oom_seen)})")
    print(f"B_STRICT_EXPORT_OK=0 reasons={joined}")
    if oom_seen:
        print("B_FAILURE_SIGNAL=CUDA_MEMORY_OR_ALLOCATION")
PY
