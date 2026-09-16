#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

if [ -L "$A_RUNS_ROOT/current" ]; then
  old=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
  oldpid=$(cat "$old/worker.pid" 2>/dev/null || true)
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "A_ALREADY_RUNNING pid=$oldpid run=$old" >&2
    exit 1
  fi
fi

bash "$ROOT/preflight.sh"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$A_RUNS_ROOT/$stamp"
INPUT_DIR="$RUN_DIR/input"
mkdir -p "$INPUT_DIR" "$A_RUNS_ROOT"
cp "$ROOT/a/periodic_train_eval.py" "$RUN_DIR/metric_train_eval_worker.py"
cp "$ROOT/data/training_records.jsonl" "$INPUT_DIR/training_records.jsonl"
cp "$ROOT/data/eval_prompts.jsonl" "$INPUT_DIR/eval_prompts.jsonl"
chmod 755 "$RUN_DIR/metric_train_eval_worker.py"
ln -sfn "$RUN_DIR" "$A_RUNS_ROOT/current"

cat > "$RUN_DIR/launch_worker.sh" <<EOF
#!/bin/bash
set -euo pipefail
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 WANDB_DISABLED=true DISABLE_VERSION_CHECK=1
export PYTHONUNBUFFERED=1 TOKENIZERS_PARALLELISM=false OMP_NUM_THREADS=\${OMP_NUM_THREADS:-8}
export NCCL_DEBUG=warn NCCL_IB_DISABLE=0 NCCL_P2P_DISABLE=0 CUDA_DEVICE_MAX_CONNECTIONS=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True,max_split_size_mb:256
export PYTHONPATH="$QWEN35_FASTPATH:$LLAMAFACTORY_ROOT/src:\${PYTHONPATH:-}"
exec python "$RUN_DIR/metric_train_eval_worker.py" \\
  --model "$A_MODEL_PATH" \\
  --train-data "$INPUT_DIR/training_records.jsonl" \\
  --eval-data "$INPUT_DIR/eval_prompts.jsonl" \\
  --run-dir "$RUN_DIR" \\
  --train-steps "$A_TRAIN_STEPS" \\
  --eval-every-steps "$A_EVAL_EVERY_STEPS" \\
  --train-seq-len "$A_TRAIN_SEQ_LEN" \\
  --eval-seq-len "$A_EVAL_SEQ_LEN" \\
  --train-batch-size "$A_TRAIN_BATCH_SIZE" \\
  --eval-batch-size "$A_EVAL_BATCH_SIZE" \\
  --eval-batches-per-burst "$A_EVAL_BATCHES_PER_BURST" \\
  --learning-rate "$A_LEARNING_RATE"
EOF
chmod 755 "$RUN_DIR/launch_worker.sh"
sha256sum "$RUN_DIR/metric_train_eval_worker.py" "$INPUT_DIR/training_records.jsonl" "$INPUT_DIR/eval_prompts.jsonl" "$RUN_DIR/launch_worker.sh" > "$RUN_DIR/inputs.sha256" 2>/dev/null || true

if id agentb >/dev/null 2>&1; then
  chown -R agentb:agentb "$A_RUNS_ROOT"
  runuser -u agentb -- bash -c 'cd "$1"; nohup setsid ./launch_worker.sh > train_eval.log 2>&1 < /dev/null & printf "%s\n" "$!" > worker.pid; printf "%s\n" "$(date -u +%FT%TZ)" > started_at' _ "$RUN_DIR"
else
  (cd "$RUN_DIR"; nohup setsid ./launch_worker.sh > train_eval.log 2>&1 < /dev/null & printf "%s\n" "$!" > worker.pid; printf "%s\n" "$(date -u +%FT%TZ)" > started_at)
fi

pid=$(cat "$RUN_DIR/worker.pid" 2>/dev/null || true)
echo "A_STARTED pid=$pid run=$RUN_DIR log=$RUN_DIR/train_eval.log"
