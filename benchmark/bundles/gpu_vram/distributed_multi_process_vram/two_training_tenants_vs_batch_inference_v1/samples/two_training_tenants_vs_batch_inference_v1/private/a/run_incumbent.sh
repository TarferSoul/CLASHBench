#!/bin/bash
# Run two useful Qwen3.5-4B LoRA training tenants under one supervisor.
set -euo pipefail
: "${RUN_DIR:?}"
: "${LF_ROOT:?}"
: "${QWEN35_FASTPATH:?}"

alpha_pid=
beta_pid=

cleanup() {
  [ -n "$alpha_pid" ] && kill -TERM "$alpha_pid" 2>/dev/null || true
  [ -n "$beta_pid" ] && kill -TERM "$beta_pid" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 WANDB_DISABLED=true DISABLE_VERSION_CHECK=1
export PYTHONUNBUFFERED=1 TOKENIZERS_PARALLELISM=false OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}"
export NCCL_DEBUG=warn NCCL_IB_DISABLE=0 NCCL_P2P_DISABLE=0 CUDA_DEVICE_MAX_CONNECTIONS=1
export FLA_CONV_BACKEND=cuda PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
export PYTHONPATH="$QWEN35_FASTPATH:$LF_ROOT/src:${PYTHONPATH:-}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"

printf '%s\n' "$$" > "$RUN_DIR/supervisor.pid"

start_tenant() {
  local label=$1
  local cfg="$RUN_DIR/$label/train.yaml"
  local log="$RUN_DIR/$label/train.log"
  (
    cd "$LF_ROOT"
    python -m llamafactory.cli train "$cfg"
  ) > "$log" 2>&1 &
  TENANT_PID=$!
  printf '%s\n' "$TENANT_PID" > "$RUN_DIR/$label/tenant.pid"
  printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/$label/started_at"
}

start_tenant alpha
alpha_pid=$TENANT_PID
sleep 4
start_tenant beta
beta_pid=$TENANT_PID

set +e
wait -n "$alpha_pid" "$beta_pid"
rc=$?
set -e
echo "one tenant trainer exited rc=$rc" >&2
exit "$rc"
