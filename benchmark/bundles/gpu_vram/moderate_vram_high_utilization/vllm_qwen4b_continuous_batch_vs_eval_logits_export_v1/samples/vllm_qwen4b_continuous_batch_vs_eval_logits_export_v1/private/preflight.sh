#!/bin/bash
# One-shot H200/runtime validation. This does not wait for workloads.
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

fail=()

[ -f "$A_MODEL_PATH/config.json" ] || fail+=("missing_Qwen3.5-4B_model_config")
[ -x "$A_VLLM_PYTHON" ] || fail+=("missing_vllm_python")
[ -f "$A_PRIVATE_REQUESTS" ] || fail+=("missing_A_request_set")
[ -f "$A_DRIVER_PROGRAM" ] || fail+=("missing_A_driver_program")
[ -f "$B_ORACLE_PROGRAM" ] || fail+=("missing_B_export_program")
[ -f "$B_CANONICAL_REQUESTS" ] || fail+=("missing_B_request_set")

if [ -f "$B_CANONICAL_REQUESTS" ]; then
  rows=$(wc -l < "$B_CANONICAL_REQUESTS" | tr -d ' ')
  [ "$rows" = "$B_EXPECTED_EXAMPLES" ] || fail+=("B_request_count_expected_${B_EXPECTED_EXAMPLES}_got_${rows}")
fi
if [ -f "$A_PRIVATE_REQUESTS" ]; then
  rows=$(wc -l < "$A_PRIVATE_REQUESTS" | tr -d ' ')
  [ "$rows" -ge 8 ] || fail+=("A_request_set_too_small_${rows}")
fi

command -v nvidia-smi >/dev/null 2>&1 || fail+=("missing_nvidia_smi")
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')
  [ "$gpu_count" = 1 ] || fail+=("expected_one_visible_GPU_got_${gpu_count}")
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  [[ "$gpu_name" = *H200* ]] || fail+=("expected_H200_got_${gpu_name// /_}")
  existing=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | sed '/^$/d' | paste -sd, -)
  [ -z "$existing" ] || [ "${ALLOW_DIRTY_GPU_FOR_DEBUG:-0}" = 1 ] || fail+=("GPU_not_clean_existing_pids=$existing")
fi

env -u PYTHONPATH "$A_VLLM_PYTHON" -c 'import vllm' >/dev/null 2>&1 || fail+=("vllm_import_failed")
python3 -m py_compile "$A_DRIVER_PROGRAM" "$B_ORACLE_PROGRAM" >/dev/null 2>&1 || fail+=("python_helper_compile_failed")
python3 - <<'PY' >/dev/null 2>&1 || fail+=("torch_transformers_import_failed")
import torch
import transformers
PY

if [ "${#fail[@]}" -eq 0 ]; then
  echo "PREFLIGHT_OK=1 one_clean_H200=1 model=Qwen3.5-4B vllm=1 export_requests=$B_EXPECTED_EXAMPLES"
else
  joined=$(IFS=';'; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 $joined"
  exit 1
fi

