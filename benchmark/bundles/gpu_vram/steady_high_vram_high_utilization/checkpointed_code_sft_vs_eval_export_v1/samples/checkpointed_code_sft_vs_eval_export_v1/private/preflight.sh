#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"

require_path() {
  local path=$1 label=$2
  [ -e "$path" ] || { echo "PREFLIGHT_OK=0 missing_${label}=$path"; exit 1; }
}

command -v nvidia-smi >/dev/null 2>&1 || { echo "PREFLIGHT_OK=0 missing_nvidia_smi=1"; exit 1; }
gpu_lines=$(nvidia-smi -L 2>/dev/null | sed -n '/GPU /p')
gpu_count=$(printf '%s\n' "$gpu_lines" | sed '/^$/d' | wc -l | tr -d ' ')
[ "$gpu_count" = 1 ] || { echo "PREFLIGHT_OK=0 gpu_count=$gpu_count expected=1"; exit 1; }
printf '%s\n' "$gpu_lines" | grep -q 'H200' || { echo "PREFLIGHT_OK=0 gpu_model_not_h200 lines=$(printf '%s' "$gpu_lines" | tr ' ' '_')"; exit 1; }

require_path "$A_LF_ROOT" "llamafactory"
require_path "$A_LF_ROOT/src" "llamafactory_src"
require_path "$QWEN35_FASTPATH" "qwen_fastpath"
require_path "$MODEL_PATH/config.json" "qwen35_4b_config"
require_path "$ROOT/data/dataset_info.json" "dataset_info"
require_path "$ROOT/data/code_agent_checkpoint_sft.jsonl" "a_seed_corpus"
require_path "$ROOT/data/eval_suite/shard_000.jsonl" "eval_shard_000"
require_path "$ROOT/data/eval_suite/shard_001.jsonl" "eval_shard_001"
require_path "$ROOT/data/ml_tasks/export_qwen35_logits.py" "export_helper"

(
cd "$ROOT"
python3 - <<'PY'
import json
from pathlib import Path
for path in [
    Path("data/dataset_info.json"),
    Path("fixture.json"),
    Path("data/eval_suite/shard_000.jsonl"),
    Path("data/eval_suite/shard_001.jsonl"),
]:
    if path.suffix == ".jsonl":
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                if line.strip():
                    json.loads(line)
    else:
        json.loads(path.read_text(encoding="utf-8"))
PY
)

if [ "${ALLOW_BUSY_GPU_PREFLIGHT:-0}" != 1 ]; then
  busy=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  [ "$busy" = 0 ] || { echo "PREFLIGHT_OK=0 gpu_compute_processes=$busy"; exit 1; }
fi

nvidia-smi --query-gpu=name,memory.total,driver_version,uuid --format=csv,noheader,nounits 2>/dev/null | sed 's/^/GPU_IDENTITY /'
echo "PREFLIGHT_OK=1 gpu_count=$gpu_count model_path=$MODEL_PATH"
