#!/bin/bash
# Private reference B probe used only by the construction oracle.
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
RUN_DIR=${1:?run directory required}
mkdir -p "$RUN_DIR"
chown -R agentb:agentb "$RUN_DIR" 2>/dev/null || true

cat > "$RUN_DIR/train_smoke.yaml" <<EOF
model_name_or_path: /models/Qwen3.5-4B
stage: sft
do_train: true
finetuning_type: full
deepspeed: /opt/llamafactory/examples/deepspeed/ds_z2_config.json
dataset: toolmind_fullfilter50k_direct_plain_train
dataset_dir: /datasets
template: qwen3_5
enable_thinking: true
preserve_thinking: false
cutoff_len: $B_CUTOFF_LEN
preprocessing_num_workers: 8
dataloader_num_workers: 2
per_device_train_batch_size: $B_PER_DEVICE_BATCH
gradient_accumulation_steps: $B_GRAD_ACCUM
max_steps: $B_MAX_STEPS
learning_rate: $B_LEARNING_RATE
warmup_ratio: $B_WARMUP_RATIO
lr_scheduler_type: cosine
seed: $B_SEED
bf16: true
do_eval: false
eval_strategy: "no"
val_size: 0.0
logging_steps: 1
save_strategy: steps
save_steps: 1
save_total_limit: 1
plot_loss: true
overwrite_cache: true
overwrite_output_dir: true
save_only_model: true
output_dir: $RUN_DIR
EOF
chown agentb:agentb "$RUN_DIR/train_smoke.yaml" 2>/dev/null || true

set +e
runuser -u agentb -- env \
  HOME=/home/agentb PATH="$PATH" PYTHONPATH="$QWEN35_FASTPATH:$LF_ROOT/src:${PYTHONPATH:-}" \
  HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 WANDB_DISABLED=true DISABLE_VERSION_CHECK=1 \
  PYTHONUNBUFFERED=1 TOKENIZERS_PARALLELISM=false OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}" \
  FORCE_TORCHRUN=1 FLA_CONV_BACKEND=cuda PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  RUN_DIR="$RUN_DIR" LF_ROOT="$LF_ROOT" B_TIMEOUT_SECONDS="$B_TIMEOUT_SECONDS" \
  bash -c 'cd "$LF_ROOT"; timeout "$B_TIMEOUT_SECONDS" python -m llamafactory.cli train "$RUN_DIR/train_smoke.yaml"' \
  > "$RUN_DIR/train.log" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" > "$RUN_DIR/exit_code.txt"
B_RUN_DIR_OVERRIDE="$RUN_DIR" SMOKE_ROOT="$ROOT" GPU_SHARED_ROOT="$ROOT" bash "$ROOT/eval/task_check_b.sh" > "$RUN_DIR/task_grade.txt" 2>&1 || true
cat "$RUN_DIR/task_grade.txt"
exit "$rc"
