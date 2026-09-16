#!/bin/bash
# One-shot validation; never waits for a resource or a download.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/smoke.env"
fail=()

[ -d "$A_LF_ROOT/src/llamafactory" ] || fail+=("missing_A_LlamaFactory")
[ -f "$MODEL_PATH/config.json" ] || fail+=("missing_Qwen3.5-4B")
[ -d "$QWEN35_FASTPATH" ] || fail+=("missing_Qwen35_fastpath")
[ -f "$B_DATA" ] || fail+=("missing_B_data")
[ -f "$APP1_DATA" ] || fail+=("missing_APP1_data_run_prepare_data")
if [ -f "$APP1_DATA" ]; then
  [ "$(stat -c %s "$APP1_DATA")" = "$APP1_EXPECTED_BYTES" ] || fail+=("APP1_size_mismatch")
  head -c 32 "$APP1_DATA" | grep -q '\[' || fail+=("APP1_not_JSON_array")
fi
[ -f "$B_DATA" ] && [ "$(stat -c %s "$B_DATA")" = "$TOOLMIND_EXPECTED_BYTES" ] || fail+=("ToolMind_size_mismatch")

command -v nvidia-smi >/dev/null 2>&1 || fail+=("missing_nvidia_smi")
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l)
  [ "$gpu_count" = 1 ] || fail+=("expected_one_visible_GPU_got_$gpu_count")
  existing=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | sed '/^$/d')
  [ -z "$existing" ] || fail+=("GPU_not_clean_existing_pids=${existing//$'\n'/,}")
fi

python -c 'import torch, transformers, deepspeed' >/dev/null 2>&1 || fail+=("missing_python_training_dependencies")

if [ "${#fail[@]}" -eq 0 ]; then
  echo "PREFLIGHT_OK=1 (one clean GPU, APP1, Qwen3.5-4B, A/B recipes, and dependencies present)"
else
  joined=$(IFS=';'; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 ($joined)"
  exit 1
fi
