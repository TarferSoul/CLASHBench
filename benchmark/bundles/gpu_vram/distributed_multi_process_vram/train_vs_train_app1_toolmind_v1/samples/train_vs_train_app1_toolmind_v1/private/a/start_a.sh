#!/bin/bash
# Starts A asynchronously and returns its run directory, launcher pid, and log path.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/smoke.env"

if [ -L "$A_RUNS_ROOT/current" ]; then
  old=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
  oldpid=$(cat "$old/launcher.pid" 2>/dev/null || true)
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "A_ALREADY_RUNNING pid=$oldpid run=$old" >&2
    exit 1
  fi
fi

bash "$ROOT/preflight.sh"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$A_RUNS_ROOT/$stamp"
mkdir -p "$RUN_DIR/checkpoints" "$A_RUNS_ROOT"
sed "s|__OUTPUT_DIR__|$RUN_DIR/checkpoints|g" "$ROOT/a/train_app1_q35_4b_single_h200.yaml.in" > "$RUN_DIR/train.yaml"
ln -sfn "$RUN_DIR" "$A_RUNS_ROOT/current"

unset https_proxy http_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export no_proxy=localhost,h.pjlab.org.cn,.pjh-service.org.cn,.pjlab.org.cn,10.0.0.0/8,100.96.0.0/12
export NO_PROXY="$no_proxy"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 WANDB_DISABLED=true DISABLE_VERSION_CHECK=1
export PYTHONUNBUFFERED=1 OMP_NUM_THREADS=8 NCCL_DEBUG=warn
export NCCL_IB_DISABLE=0 NCCL_P2P_DISABLE=0 CUDA_DEVICE_MAX_CONNECTIONS=1
export FORCE_TORCHRUN=1 FLA_CONV_BACKEND=cuda
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export PYTHONPATH="$QWEN35_FASTPATH:$A_LF_ROOT/src:${PYTHONPATH:-}"

cd "$A_LF_ROOT"
nohup setsid python -m llamafactory.cli train "$RUN_DIR/train.yaml" > "$RUN_DIR/train.log" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$RUN_DIR/launcher.pid"
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/started_at"
sha256sum "$APP1_DATA" "$RUN_DIR/train.yaml" > "$RUN_DIR/inputs.sha256"
echo "A_STARTED pid=$pid run=$RUN_DIR log=$RUN_DIR/train.log"
