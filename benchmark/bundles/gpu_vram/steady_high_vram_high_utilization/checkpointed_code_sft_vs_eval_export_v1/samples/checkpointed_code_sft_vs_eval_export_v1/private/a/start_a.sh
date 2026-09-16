#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

run_user=${A_RUN_AS_USER:-agentb}
if ! id "$run_user" >/dev/null 2>&1; then
  echo "A_START_FAIL missing_user=$run_user" >&2
  exit 1
fi

if [ -L "$A_RUNS_ROOT/current" ]; then
  old=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
  old_pid=$(cat "$old/launcher.pid" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A_ALREADY_RUNNING pid=$old_pid run=$old" >&2
    exit 1
  fi
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$A_RUNS_ROOT/$stamp"
OUTPUT_DIR="$RUN_DIR/$A_TRAIN_OUTPUT_SUBDIR"
mkdir -p "$OUTPUT_DIR" "$A_RUNS_ROOT"
sed \
  -e "s|__OUTPUT_DIR__|$OUTPUT_DIR|g" \
  -e "s|__DATASET_DIR__|$A_DATASET_DIR|g" \
  "$ROOT/a/train_code_sft_q35_4b_h200.yaml.in" > "$RUN_DIR/train.yaml"
ln -sfn "$RUN_DIR" "$A_RUNS_ROOT/current"
chown -R "$run_user:$run_user" "$A_RUNS_ROOT"
sha256sum "$A_DATASET_DIR/code_agent_checkpoint_sft.jsonl" "$RUN_DIR/train.yaml" > "$RUN_DIR/inputs.sha256" 2>/dev/null || true

unset https_proxy http_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export no_proxy="${no_proxy:-localhost,127.0.0.1,h.pjlab.org.cn,.pjh-service.org.cn,.pjlab.org.cn,10.0.0.0/8,100.96.0.0/12}"
export NO_PROXY="$no_proxy"

runuser -u "$run_user" -- env HOME="/home/$run_user" PATH="$PATH" \
  HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 WANDB_DISABLED=true DISABLE_VERSION_CHECK=1 \
  PYTHONUNBUFFERED=1 OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}" NCCL_DEBUG=warn \
  NCCL_IB_DISABLE=0 NCCL_P2P_DISABLE=0 CUDA_DEVICE_MAX_CONNECTIONS=1 FORCE_TORCHRUN=1 \
  FLA_CONV_BACKEND=cuda PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
  QWEN35_FASTPATH="$QWEN35_FASTPATH" A_LF_ROOT="$A_LF_ROOT" RUN_DIR="$RUN_DIR" \
  PYTHONPATH="$QWEN35_FASTPATH:$A_LF_ROOT/src:${PYTHONPATH:-}" \
  bash -lc 'cd "$A_LF_ROOT"; nohup setsid python -m llamafactory.cli train "$RUN_DIR/train.yaml" > "$RUN_DIR/train.log" 2>&1 < /dev/null & printf "%s\n" "$!" > "$RUN_DIR/launcher.pid"; printf "%s\n" "$(date -u +%FT%TZ)" > "$RUN_DIR/started_at"'

pid=$(cat "$RUN_DIR/launcher.pid" 2>/dev/null || true)
echo "A_STARTED pid=$pid run=$RUN_DIR log=$RUN_DIR/train.log"
