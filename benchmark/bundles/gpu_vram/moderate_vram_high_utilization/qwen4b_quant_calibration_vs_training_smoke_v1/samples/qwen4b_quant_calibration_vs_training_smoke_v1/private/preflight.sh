#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

fail=()

[ -f "$A_MODEL_PATH/config.json" ] || fail+=("missing_Qwen3.5-4B_model_config")
[ -x "$A_PYTHON" ] || fail+=("missing_qwen35_runtime_python")
[ -f "$A_PROGRAM" ] || fail+=("missing_calibration_program")
[ -f "$A_PRIVATE_CORPUS" ] || fail+=("missing_calibration_corpus")
[ -f "$B_ORACLE_PROGRAM" ] || fail+=("missing_training_smoke_program")
[ -f "$B_CANONICAL_CORPUS" ] || fail+=("missing_training_smoke_corpus")

if [ -f "$A_PRIVATE_CORPUS" ]; then
  rows=$(wc -l < "$A_PRIVATE_CORPUS" | tr -d ' ')
  [ "$rows" -ge 8 ] || fail+=("calibration_corpus_too_small_${rows}")
fi
if [ -f "$B_CANONICAL_CORPUS" ]; then
  rows=$(wc -l < "$B_CANONICAL_CORPUS" | tr -d ' ')
  [ "$rows" -ge "$B_EXPECTED_STEPS" ] || fail+=("training_corpus_too_small_${rows}")
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

"$A_PYTHON" -m py_compile "$A_PROGRAM" "$B_ORACLE_PROGRAM" >/dev/null 2>&1 || fail+=("python_helper_compile_failed")
"$A_PYTHON" - <<'PY' >/dev/null 2>&1 || fail+=("torch_transformers_import_failed")
import torch
import transformers
PY

if [ "${#fail[@]}" -eq 0 ]; then
  echo "PREFLIGHT_OK=1 one_clean_H200=1 model=Qwen3.5-4B calibration_corpus=1 training_smoke=1"
else
  joined=$(IFS=';'; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 $joined"
  exit 1
fi
