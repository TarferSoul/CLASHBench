#!/bin/bash
# One-shot runtime validation. It does not launch a CUDA workload.
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
fail=()

[ -d "$LF_ROOT/src/llamafactory" ] || fail+=("missing_LLaMA-Factory")
[ -d "$QWEN35_FASTPATH" ] || fail+=("missing_Qwen35_fastpath")
[ -f "$A_MODEL_PATH/config.json" ] || fail+=("missing_Qwen3.5-4B")
[ -f "$B_MODEL_PATH/config.json" ] || fail+=("missing_Qwen3.5-35B-A3B")
[ -f /datasets/dataset_info.json ] || fail+=("missing_dataset_info")
[ -f "$A_ALPHA_DATA_FILE" ] || fail+=("missing_alpha_dataset")
[ -f "$A_BETA_DATA_FILE" ] || fail+=("missing_beta_dataset")
[ -f "$ROOT/data/batch_requests.jsonl" ] || fail+=("missing_batch_requests")
[ -f "$ROOT/data/export_qwen_batch.py" ] || fail+=("missing_export_helper")

if [ -f "$A_ALPHA_DATA_FILE" ]; then
  size=$(stat -Lc %s "$A_ALPHA_DATA_FILE" 2>/dev/null || echo 0)
  [ "$size" -ge 1000000 ] || fail+=("alpha_dataset_too_small")
fi
if [ -f "$A_BETA_DATA_FILE" ]; then
  size=$(stat -Lc %s "$A_BETA_DATA_FILE" 2>/dev/null || echo 0)
  [ "$size" -ge 1000000 ] || fail+=("beta_dataset_too_small")
fi

python3 - "$ROOT/data/batch_requests.jsonl" "$B_EXPECTED_ROWS" <<'PY' >/dev/null 2>&1 || fail+=("bad_batch_requests")
import json
import sys
path, expected = sys.argv[1], int(sys.argv[2])
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
assert len(rows) == expected
assert len({row["id"] for row in rows}) == expected
assert all(row.get("prompt") for row in rows)
PY

command -v nvidia-smi >/dev/null 2>&1 || fail+=("missing_nvidia_smi")
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_count=$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')
  [ "$gpu_count" = 1 ] || fail+=("expected_one_visible_GPU_got_$gpu_count")
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  [[ "$gpu_name" = *H200* ]] || fail+=("expected_H200_got_${gpu_name// /_}")
  existing=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader,nounits 2>/dev/null | tr -d ' ' | sed '/^$/d' || true)
  [ -z "$existing" ] || fail+=("GPU_not_clean_existing_pids=${existing//$'\n'/,}")
fi

python3 -c 'import torch, transformers, yaml' >/dev/null 2>&1 || fail+=("missing_training_or_transformers_runtime")

if [ "${#fail[@]}" -eq 0 ]; then
  echo "PREFLIGHT_OK=1 (one clean H200, Qwen models, shared datasets, LLaMA-Factory, and export helper present)"
else
  joined=$(IFS=';'; echo "${fail[*]}")
  echo "PREFLIGHT_OK=0 ($joined)"
  exit 1
fi
