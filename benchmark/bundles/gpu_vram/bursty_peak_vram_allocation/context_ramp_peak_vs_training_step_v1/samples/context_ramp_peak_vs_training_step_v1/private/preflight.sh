#!/bin/bash
# Static one-shot runtime preflight. It does not start a CUDA workload.
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
fail=()

[ -f "$A_MODEL_PATH/config.json" ] || fail+=("missing_Qwen3.5-35B-A3B")
[ -f "$B_MODEL_PATH/config.json" ] || fail+=("missing_Qwen3.5-4B")
[ -d "$LF_ROOT/src/llamafactory" ] || fail+=("missing_LlamaFactory")
[ -d "$QWEN35_FASTPATH" ] || fail+=("missing_Qwen35_fastpath")
[ -f "$A_CONTEXT_RAMP_SCHEDULE" ] || fail+=("missing_context_ramp_schedule")
[ -f "$B_DATASET_DIR/dataset_info.json" ] || fail+=("missing_dataset_info")
[ -f "$B_DATASET_DIR/toolmind_fullfilter50k_direct_plain_train.json" ] || fail+=("missing_ToolMind50K")
if [ -f "$B_DATASET_DIR/toolmind_fullfilter50k_direct_plain_train.json" ]; then
  [ "$(stat -c %s "$B_DATASET_DIR/toolmind_fullfilter50k_direct_plain_train.json")" = 345135317 ] || fail+=("ToolMind50K_size_mismatch")
fi

command -v nvidia-smi >/dev/null 2>&1 || fail+=("missing_nvidia_smi")
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')
  [ "$gpu_count" = 1 ] || fail+=("expected_one_visible_GPU_got_$gpu_count")
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  [[ "$gpu_name" = *H200* ]] || fail+=("expected_H200_got_${gpu_name// /_}")
  existing=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | sed '/^$/d')
  [ -z "$existing" ] || fail+=("GPU_not_clean_existing_pids=${existing//$'\n'/,}")
fi

env -u PYTHONPATH "$A_VLLM_PYTHON" -c 'import vllm; print(vllm.__version__)' >/dev/null 2>&1 || fail+=("missing_vllm_runtime")
python3 - <<'PY' >/dev/null 2>&1 || fail+=("invalid_context_ramp_schedule")
import json
import os
path = os.environ.get("A_CONTEXT_RAMP_SCHEDULE", "/benchdata/context_ramp_schedule.json")
doc = json.load(open(path))
phases = doc["phases"]
assert any(p["phase"] == "long_context_peak" and p["requests"] >= 1 for p in phases)
assert any(p["phase"].startswith("short_context") for p in phases)
PY
python3 -c 'import torch, transformers, deepspeed, yaml' >/dev/null 2>&1 || fail+=("missing_training_runtime")

if [ "${#fail[@]}" -eq 0 ]; then
  echo "PREFLIGHT_OK=1 resource=gpu_vram hardware=one_H200 assets=models,dataset,llamafactory,vllm"
else
  joined=$(IFS=';'; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 ($joined)"
  exit 1
fi
