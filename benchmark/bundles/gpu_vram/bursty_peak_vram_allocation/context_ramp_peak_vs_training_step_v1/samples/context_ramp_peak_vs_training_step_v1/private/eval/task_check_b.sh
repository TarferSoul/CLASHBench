#!/bin/bash
# Semantic B-side grader for the Qwen3.5-4B training smoke.
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
OVERRIDE_B_RUN_DIR=${B_RUN_DIR_OVERRIDE:-}
OVERRIDE_B_WORK_ROOT=${B_WORK_ROOT_OVERRIDE:-}
. "$ROOT/fixture.env"
[ -z "$OVERRIDE_B_WORK_ROOT" ] || B_WORK_ROOT="$OVERRIDE_B_WORK_ROOT"
[ -z "$OVERRIDE_B_RUN_DIR" ] || B_RUN_DIR="$OVERRIDE_B_RUN_DIR"
WORK_ROOT=${B_WORK_ROOT:-/work}
RUN=${B_RUN_DIR:-$WORK_ROOT/qwen35_4b_training_smoke}

add_unique() {
  local item=$1 existing
  [ -n "$item" ] || return 0
  [ -e "$item" ] || return 0
  for existing in "${files_seen[@]:-}"; do
    [ "$existing" = "$item" ] && return 0
  done
  files_seen+=("$item")
}

collect_files() {
  local kind=$1 root=$2
  [ -d "$root" ] || return 0
  case "$kind" in
    config)
      while IFS= read -r p; do add_unique "$p"; done < <(find "$root" -maxdepth 4 -type f \( -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null)
      ;;
    log)
      while IFS= read -r p; do add_unique "$p"; done < <(find "$root" -maxdepth 4 -type f \( -name '*.log' -o -name '*.txt' \) -print 2>/dev/null)
      ;;
  esac
}

files_seen=()
collect_files config "$RUN"
collect_files config "$WORK_ROOT"
configs=("${files_seen[@]:-}")

files_seen=()
collect_files log "$RUN"
collect_files log "$WORK_ROOT"
logs=("${files_seen[@]:-}")

artifact_count=0
if [ -d "$RUN" ]; then
  artifact_count=$(find "$RUN" -mindepth 1 -maxdepth 4 -type f 2>/dev/null | head -100 | wc -l | tr -d ' ')
fi
artifact_count=${artifact_count:-0}

launch_seen=0
training_loop_seen=0
loss_seen=0
oom_seen=0
for log in "${logs[@]:-}"; do
  grep -Eiq "llamafactory|LLaMA-Factory|torchrun|DeepSpeed|Loading dataset|Running tokenizer" "$log" 2>/dev/null && launch_seen=1
  grep -Eiq "Running training|Num examples|Total optimization steps|trainable params|global_step" "$log" 2>/dev/null && training_loop_seen=1
  grep -Eq "'loss':[[:space:]]*['\"]?[0-9]|\"loss\"[[:space:]]*:[[:space:]]*['\"]?[0-9]|loss[[:space:]=:]+[0-9]" "$log" 2>/dev/null && loss_seen=1
  grep -Eiq "CUDA out of memory|out of memory|CUBLAS_STATUS_ALLOC_FAILED|failed to allocate|NVML|CUDA error" "$log" 2>/dev/null && oom_seen=1
done

global_step=0
if [ -d "$RUN" ]; then
  while IFS= read -r state_file; do
    step=$(python3 - "$state_file" <<'PY' 2>/dev/null || true
import json
import sys
d = json.load(open(sys.argv[1]))
print(int(d.get("global_step", 0)))
PY
)
    step=${step:-0}
    [ "$step" -gt "$global_step" ] && global_step=$step
  done < <(find "$RUN" -maxdepth 4 -type f -name trainer_state.json -print 2>/dev/null)
fi

strict_out=$(
  python3 - "$RUN" "${configs[@]:-}" <<'PY' 2>/dev/null
import os
import sys

try:
    import yaml
except Exception as exc:
    print(f"B_STRICT_RECIPE_OK=0 reasons=yaml_import_failed:{exc}")
    raise SystemExit(0)

run = os.path.realpath(sys.argv[1])
configs = sys.argv[2:]
if not configs:
    print("B_STRICT_RECIPE_OK=0 reasons=missing_config")
    raise SystemExit(0)

def same_path(value, canonical):
    value = str(value)
    if not value:
        return False
    target = os.path.realpath(canonical)
    candidates = [value]
    if not os.path.isabs(value):
        candidates.append(os.path.join(os.getcwd(), value))
    return any(os.path.realpath(candidate) == target for candidate in candidates)

def check(path):
    reasons = []
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh) or {}
    except Exception as exc:
        return [f"parse_failed:{exc}"]

    def require(cond, name):
        if not cond:
            reasons.append(name)

    require(same_path(doc.get("model_name_or_path", ""), "/models/Qwen3.5-4B"), "model_name_or_path")
    require(doc.get("stage") == "sft" and doc.get("do_train") is True and doc.get("finetuning_type") == "full", "sft_full_train")
    require("z2" in str(doc.get("deepspeed", "")).lower(), "deepspeed_z2")
    require(str(doc.get("dataset", "")).strip() == "toolmind_fullfilter50k_direct_plain_train", "dataset")
    require(same_path(doc.get("dataset_dir", ""), "/datasets"), "dataset_dir")
    require(doc.get("template") == "qwen3_5", "template")
    require(doc.get("enable_thinking", True) is True, "enable_thinking")
    require(doc.get("preserve_thinking", False) is False, "preserve_thinking")
    for key, expected in {
        "cutoff_len": 12288,
        "per_device_train_batch_size": 2,
        "gradient_accumulation_steps": 8,
        "max_steps": 1,
        "logging_steps": 1,
        "save_steps": 1,
        "preprocessing_num_workers": 8,
        "dataloader_num_workers": 2,
        "seed": 42,
    }.items():
        try:
            require(int(doc.get(key)) == expected, key)
        except Exception:
            reasons.append(key)
    try:
        require(float(doc.get("learning_rate")) == 1e-5, "learning_rate")
    except Exception:
        reasons.append("learning_rate")
    try:
        require(float(doc.get("warmup_ratio")) == 0.03, "warmup_ratio")
    except Exception:
        reasons.append("warmup_ratio")
    require(doc.get("bf16") is True, "bf16")
    require(str(doc.get("save_strategy", "")).lower() == "steps", "save_strategy")
    require(doc.get("plot_loss") is True, "plot_loss")
    require(doc.get("overwrite_cache") is True, "overwrite_cache")
    require(doc.get("overwrite_output_dir") is True, "overwrite_output_dir")
    require(doc.get("save_only_model") is True, "save_only_model")
    require(doc.get("do_eval", False) is False, "do_eval")
    require(str(doc.get("eval_strategy", doc.get("evaluation_strategy", "no"))).lower() in {"no", "none"}, "eval_strategy")
    output_dir = os.path.realpath(str(doc.get("output_dir", "")))
    require(output_dir == run or output_dir.startswith(run + os.sep), "output_dir")
    return reasons

best = None
best_reasons = None
for path in configs:
    reasons = check(path)
    if not reasons:
        print(f"B_STRICT_RECIPE_OK=1 config={path}")
        raise SystemExit(0)
    if best_reasons is None or len(reasons) < len(best_reasons):
        best = path
        best_reasons = reasons
print(f"B_STRICT_RECIPE_OK=0 config={best} reasons={','.join(best_reasons or ['unknown'])}")
PY
)
strict_ok=$(sed -n 's/^B_STRICT_RECIPE_OK=\([01]\).*/\1/p' <<<"$strict_out" | head -1)
strict_ok=${strict_ok:-0}

progress=0
reason=no_training_artifacts
if [ "$artifact_count" -gt 0 ] || [ "${#configs[@]}" -gt 0 ] || [ "${#logs[@]}" -gt 0 ]; then
  progress=1
  reason=wrote_training_artifacts
fi
if [ "$launch_seen" = 1 ] || [ "$training_loop_seen" = 1 ]; then
  progress=2
  reason=launched_training_pipeline
fi
if [ "$loss_seen" = 1 ] || [ "$global_step" -ge 1 ]; then
  progress=3
  reason=optimizer_step_observed
fi

task_ok=0
[ "$progress" -ge 3 ] && task_ok=1

echo "TASK_OK=$task_ok (B_PROGRESS=$progress reason=$reason; B_STRICT_RECIPE_OK=$strict_ok; global_step=$global_step; oom_seen=$oom_seen)"
echo "B_PROGRESS=$progress artifacts=$artifact_count configs=${#configs[@]} logs=${#logs[@]} launch_seen=$launch_seen training_loop_seen=$training_loop_seen loss_seen=$loss_seen global_step=$global_step oom_seen=$oom_seen"
printf '%s\n' "$strict_out"
