#!/bin/bash
# One-shot H200 and dependency validation. No CUDA workload is launched here.
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

fail=()

[ -f "$A_MODEL_PATH/config.json" ] || fail+=("missing_Qwen3.5-35B-A3B")
[ -f "$B_MODEL_PATH/config.json" ] || fail+=("missing_Qwen3.5-4B")
[ -x "$A_VLLM_PYTHON" ] || fail+=("missing_vllm_python")
[ -f "$A_CHAT_TEMPLATE" ] || fail+=("missing_structured_chat_template")
[ -f "$A_CANARY_SPEC" ] || fail+=("missing_structured_canary_spec")
[ -f "$ROOT/data/workspace_template/run_quant_eval.py" ] || fail+=("missing_quant_eval_runner")
[ -f "$ROOT/data/workspace_template/inputs/calibration_prompts.jsonl" ] || fail+=("missing_calibration_prompts")
[ -f "$ROOT/data/workspace_template/inputs/eval_prompts.jsonl" ] || fail+=("missing_eval_prompts")
[ -f "$B_CALIBRATION_INPUT" ] || fail+=("missing_visible_calibration_prompts")
[ -f "$B_EVAL_INPUT" ] || fail+=("missing_visible_eval_prompts")

if [ -f "$B_CALIBRATION_INPUT" ]; then
  rows=$(wc -l < "$B_CALIBRATION_INPUT" | tr -d ' ')
  [ "$rows" -ge "$B_REQUIRED_CALIBRATION_SAMPLES" ] || fail+=("too_few_calibration_rows_$rows")
fi
if [ -f "$B_EVAL_INPUT" ]; then
  rows=$(wc -l < "$B_EVAL_INPUT" | tr -d ' ')
  [ "$rows" -ge "$B_REQUIRED_EVAL_EXAMPLES" ] || fail+=("too_few_eval_rows_$rows")
fi

command -v nvidia-smi >/dev/null 2>&1 || fail+=("missing_nvidia_smi")
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')
  [ "$gpu_count" = 1 ] || fail+=("expected_one_visible_GPU_got_$gpu_count")
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  [[ "$gpu_name" = *H200* ]] || fail+=("expected_H200_got_${gpu_name// /_}")
  existing=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | sed '/^$/d' | paste -sd, -)
  [ -z "$existing" ] || fail+=("GPU_not_clean_existing_pids=$existing")
fi

env -u PYTHONPATH "$A_VLLM_PYTHON" -c 'import vllm' >/dev/null 2>&1 || fail+=("vllm_import_failed")
PYTHONPATH="/opt/qwen35_fastpath:${PYTHONPATH:-}" python3 -c 'import torch, transformers, numpy' >/dev/null 2>&1 || fail+=("quant_eval_python_import_failed")

if [ "${#fail[@]}" -eq 0 ]; then
  echo "PREFLIGHT_OK=1 (one clean H200, structured service assets, Qwen3.5-4B inputs, vLLM, and Transformers stack present)"
else
  joined=$(IFS=';'; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 ($joined)"
  exit 1
fi

