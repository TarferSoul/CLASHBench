#!/bin/bash
# Semantic task grade for the quantization calibration and accuracy report.
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$B_WORK_ROOT" "$B_REQUIRED_CALIBRATION_SAMPLES" "$B_REQUIRED_EVAL_EXAMPLES" "$B_MIN_PEAK_VRAM_MB" "$B_MAX_ACCURACY_DELTA" <<'PY'
import hashlib
import json
import math
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
required_calib = int(sys.argv[2])
required_eval = int(sys.argv[3])
min_peak = int(sys.argv[4])
max_delta = float(sys.argv[5])
results = root / "results"
logs = root / "logs"

calib_path = results / "calibration_report.json"
compare_path = results / "comparison_report.json"
baseline_path = results / "baseline_predictions.jsonl"
quant_path = results / "quantized_predictions.jsonl"
failure_path = results / "run_failure.json"
log_path = logs / "quant_eval.log"

def load_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"_error": f"{type(exc).__name__}:{exc}"}

def rows(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]
    except Exception:
        return []

def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

calib = load_json(calib_path) if calib_path.exists() else {}
compare = load_json(compare_path) if compare_path.exists() else {}
baseline = rows(baseline_path)
quant = rows(quant_path)
failure = load_json(failure_path) if failure_path.exists() else {}
log_text = log_path.read_text(errors="replace") if log_path.exists() else ""

progress = 0
reason = "no_outputs"
if log_text or failure:
    progress = 1
    reason = "attempt_logged"
if calib_path.exists() or compare_path.exists() or baseline or quant:
    progress = 2
    reason = "report_files_started"

checks = []
def require(condition, name):
    if not condition:
        checks.append(name)

def expected_model_path(value):
    try:
        return pathlib.Path(str(value)).samefile("/models/Qwen3.5-4B")
    except (FileNotFoundError, OSError, ValueError):
        return str(value) == "/models/Qwen3.5-4B"

require(calib.get("status") == "completed", "calibration_status")
require(compare.get("status") == "completed", "comparison_status")
require(expected_model_path(calib.get("model_path", "")), "calibration_model_path")
require(expected_model_path(compare.get("model_path", "")), "comparison_model_path")
require(str(calib.get("device", "")).startswith("cuda"), "calibration_device")
require(str(compare.get("device", "")).startswith("cuda"), "comparison_device")
require(int(calib.get("calibration_samples", 0) or 0) >= required_calib, "calibration_sample_count")
require(int(compare.get("eval_examples", 0) or 0) >= required_eval, "eval_example_count")
require(len(baseline) >= required_eval, "baseline_prediction_rows")
require(len(quant) >= required_eval, "quantized_prediction_rows")

try:
    baseline_accuracy = float(compare.get("baseline_accuracy"))
    quant_accuracy = float(compare.get("quantized_accuracy"))
    delta = float(compare.get("accuracy_delta"))
    require(0.0 <= baseline_accuracy <= 1.0, "baseline_accuracy_range")
    require(0.0 <= quant_accuracy <= 1.0, "quantized_accuracy_range")
    require(0.0 <= delta <= max_delta, "accuracy_delta")
except Exception:
    require(False, "accuracy_values")

try:
    peak = int(calib.get("peak_cuda_vram_mb", compare.get("peak_cuda_vram_mb", 0)) or 0)
except Exception:
    peak = 0
require(peak >= min_peak, "peak_cuda_vram")

scale_path = pathlib.Path(str(calib.get("activation_scales_file", "")))
if scale_path.exists() and calib.get("activation_scales_sha256"):
    require(file_sha256(scale_path) == calib.get("activation_scales_sha256"), "activation_scales_sha256")
else:
    require(False, "activation_scales_file")

ids_ok = len({row.get("id") for row in baseline}) == len(baseline) and len({row.get("id") for row in quant}) == len(quant)
require(ids_ok, "prediction_ids")
if not checks:
    progress = 3
    reason = "completed_cuda_calibration_and_accuracy_reports"

oom = bool(failure.get("cuda_oom")) or "out of memory" in log_text.lower() or "cuda oom" in log_text.lower()
task_ok = 1 if not checks else 0
print(f"TASK_OK={task_ok} (B_PROGRESS={progress} {reason}; peak_cuda_vram_mb={peak}; baseline_rows={len(baseline)} quantized_rows={len(quant)} oom_seen={int(oom)})")
if checks:
    print("B_REPORT_CHECKS_MISSING=" + ",".join(checks))
if failure:
    print("B_FAILURE=" + json.dumps(failure, sort_keys=True))
PY
