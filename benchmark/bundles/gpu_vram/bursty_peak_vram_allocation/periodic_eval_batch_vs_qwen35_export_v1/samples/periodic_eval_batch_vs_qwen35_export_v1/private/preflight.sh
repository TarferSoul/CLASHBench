#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"

if [ "${BENCHMARK_SANDBOX:-0}" != 1 ]; then
  echo "PREFLIGHT_OK=0 reason=sandbox_required"
  exit 90
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "PREFLIGHT_OK=0 reason=missing_nvidia_smi"
  exit 3
fi

gpu_count=$(nvidia-smi -L 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ "$gpu_count" != 1 ] || [[ "$gpu_name" != *H200* ]]; then
  echo "PREFLIGHT_OK=0 reason=requires_one_H200 observed_count=$gpu_count observed_name=${gpu_name:-unknown}"
  exit 3
fi

for path in "$A_MODEL_PATH" "$B_MODEL_PATH" "$QWEN35_FASTPATH" "$ROOT/data/training_records.jsonl" "$ROOT/data/eval_prompts.jsonl"; do
  if [ ! -e "$path" ]; then
    echo "PREFLIGHT_OK=0 reason=missing_path path=$path"
    exit 3
  fi
done

python3 - <<'PY'
import importlib
missing = []
for name in ("torch", "transformers", "peft"):
    try:
        importlib.import_module(name)
    except Exception as exc:
        missing.append(f"{name}:{exc}")
if missing:
    print("PREFLIGHT_OK=0 reason=missing_python_deps deps=" + ";".join(missing))
    raise SystemExit(3)
print("PYTHON_DEPS_OK=1")
PY

existing=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
if [ "${PREFLIGHT_ALLOW_EXISTING_GPU_PROCS:-0}" != 1 ] && [ "${existing:-0}" != 0 ]; then
  echo "PREFLIGHT_OK=0 reason=gpu_not_clean existing_compute_apps=$existing"
  exit 3
fi

echo "PREFLIGHT_OK=1 gpu_count=$gpu_count gpu_name=$gpu_name"

