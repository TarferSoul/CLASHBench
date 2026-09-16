#!/bin/bash
# One-shot validation. It never waits for a GPU, model, server, or download.
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
fail=()

[ -f "$A_MODEL_PATH/config.json" ] || fail+=("missing_Qwen3.5-35B-A3B")
[ -f "$B_MODEL_PATH/config.json" ] || fail+=("missing_Qwen3.5-4B")
[ -f "$AGENTDOG_CHAT_TEMPLATE" ] || fail+=("missing_AgentDoG_chat_template")
if [ -f "$AGENTDOG_CHAT_TEMPLATE" ]; then
  [ "$(stat -c %s "$AGENTDOG_CHAT_TEMPLATE")" = 7756 ] || fail+=("AgentDoG_chat_template_size_mismatch")
  [ "$(sha256sum "$AGENTDOG_CHAT_TEMPLATE" | awk '{print $1}')" = a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715 ] || fail+=("AgentDoG_chat_template_sha256_mismatch")
fi
[ -d "$LF_ROOT/src/llamafactory" ] || fail+=("missing_LlamaFactory")
[ -d "$QWEN35_FASTPATH" ] || fail+=("missing_Qwen35_fastpath")
[ -f "$B_DATASET_DIR/dataset_info.json" ] || fail+=("missing_dataset_info")
[ -f "$B_DATASET_DIR/toolmind_fullfilter50k_direct_plain_train.json" ] || fail+=("missing_ToolMind50K")
if [ -f "$B_DATASET_DIR/toolmind_fullfilter50k_direct_plain_train.json" ]; then
  [ "$(stat -c %s "$B_DATASET_DIR/toolmind_fullfilter50k_direct_plain_train.json")" = 345135317 ] || fail+=("ToolMind50K_size_mismatch")
fi
if [ "$A_MODE" = atbench ]; then
  [ -f "$ATBENCH_DATA" ] || fail+=("missing_ATBench")
  if [ -f "$ATBENCH_DATA" ]; then
    [ "$(stat -c %s "$ATBENCH_DATA")" = 18335079 ] || fail+=("ATBench_size_mismatch")
    [ "$(sha256sum "$ATBENCH_DATA" | awk '{print $1}')" = 80c534b5f3517c872b528a2e6b64e34495206968edd184f4aed563d39f0cca09 ] || fail+=("ATBench_sha256_mismatch")
  fi
fi

command -v nvidia-smi >/dev/null 2>&1 || fail+=("missing_nvidia_smi")
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l)
  [ "$gpu_count" = 1 ] || fail+=("expected_one_visible_GPU_got_$gpu_count")
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null)
  [[ "$gpu_name" = *H200* ]] || fail+=("expected_H200_got_${gpu_name// /_}")
  existing=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | sed '/^$/d')
  [ -z "$existing" ] || fail+=("GPU_not_clean_existing_pids=${existing//$'\n'/,}")
fi

env -u PYTHONPATH "$A_VLLM_PYTHON" -c 'import vllm; print(vllm.__version__)' >/dev/null 2>&1 || fail+=("missing_vllm_runtime")
python -c 'import torch, transformers, deepspeed, yaml' >/dev/null 2>&1 || fail+=("missing_training_runtime")

if [ "${#fail[@]}" -eq 0 ]; then
  echo "PREFLIGHT_OK=1 (mode=$A_MODE, one clean H200, both models, datasets, vLLM, and training stack present)"
else
  joined=$(IFS=';'; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 ($joined)"
  exit 1
fi
