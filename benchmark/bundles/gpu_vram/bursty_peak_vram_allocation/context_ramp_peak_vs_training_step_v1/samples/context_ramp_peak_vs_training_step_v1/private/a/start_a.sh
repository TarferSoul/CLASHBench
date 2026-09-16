#!/bin/bash
# Start the incumbent context-ramp evaluation asynchronously.
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if [ -L "$A_RUNS_ROOT/current" ]; then
  old=$(readlink -f "$A_RUNS_ROOT/current" 2>/dev/null || true)
  oldpid=$(cat "$old/launcher.pid" 2>/dev/null || true)
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "INCUMBENT_ALREADY_RUNNING pid=$oldpid run=$old" >&2
    exit 1
  fi
fi

bash "$ROOT/preflight.sh"
mkdir -p "$A_RUNS_ROOT" /opt/ml-platform
stamp=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$A_RUNS_ROOT/$stamp"
mkdir -p "$RUN_DIR"
ln -sfn "$RUN_DIR" "$A_RUNS_ROOT/current"
cp "$ROOT/a/run_context_ramp_eval.py" /opt/ml-platform/context_ramp_eval.py
chmod 755 /opt/ml-platform/context_ramp_eval.py

unset https_proxy http_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export no_proxy=localhost,127.0.0.1,h.pjlab.org.cn,.pjh-service.org.cn,.pjlab.org.cn,10.0.0.0/8,100.96.0.0/12
export NO_PROXY="$no_proxy"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1
export PYTHONUNBUFFERED=1 TOKENIZERS_PARALLELISM=false
export HF_HOME="${A_HF_HOME:-${HF_HOME:-/tmp/context-ramp-hf}}"
export HF_DATASETS_CACHE="${A_HF_DATASETS_CACHE:-${HF_DATASETS_CACHE:-/tmp/context-ramp-hf-datasets}}"
export TRANSFORMERS_CACHE="${A_TRANSFORMERS_CACHE:-${TRANSFORMERS_CACHE:-/tmp/context-ramp-transformers}}"
export XDG_CACHE_HOME="${A_XDG_CACHE_HOME:-${XDG_CACHE_HOME:-/tmp/context-ramp-xdg}}"
export TRITON_CACHE_DIR="${A_TRITON_CACHE_DIR:-${TRITON_CACHE_DIR:-/tmp/context-ramp-triton}}"
export MPLCONFIGDIR="${A_MPLCONFIGDIR:-${MPLCONFIGDIR:-/tmp/context-ramp-matplotlib}}"
export FLASHINFER_WORKSPACE_DIR="${A_FLASHINFER_WORKSPACE_DIR:-${FLASHINFER_WORKSPACE_DIR:-/tmp/context-ramp-flashinfer}}"
export TORCHINDUCTOR_CACHE_DIR="${A_TORCHINDUCTOR_CACHE_DIR:-${TORCHINDUCTOR_CACHE_DIR:-/tmp/context-ramp-torchinductor}}"
export CUDA_CACHE_PATH="${A_CUDA_CACHE_PATH:-${CUDA_CACHE_PATH:-/tmp/context-ramp-cuda}}"

chown -R agentb:agentb "$A_RUNS_ROOT" 2>/dev/null || true
sha256sum "$A_MODEL_PATH/config.json" "$A_CONTEXT_RAMP_SCHEDULE" "$ROOT/fixture.env" > "$RUN_DIR/inputs.sha256" 2>/dev/null || true

cd "$RUN_DIR"
setsid runuser -u agentb -- env -u PYTHONPATH \
  HOME=/home/agentb PATH="$PATH" \
  HF_HUB_OFFLINE="$HF_HUB_OFFLINE" TRANSFORMERS_OFFLINE="$TRANSFORMERS_OFFLINE" \
  VLLM_NO_USAGE_STATS="$VLLM_NO_USAGE_STATS" DO_NOT_TRACK="$DO_NOT_TRACK" \
  PYTHONUNBUFFERED="$PYTHONUNBUFFERED" TOKENIZERS_PARALLELISM="$TOKENIZERS_PARALLELISM" \
  HF_HOME="$HF_HOME" HF_DATASETS_CACHE="$HF_DATASETS_CACHE" TRANSFORMERS_CACHE="$TRANSFORMERS_CACHE" \
  XDG_CACHE_HOME="$XDG_CACHE_HOME" TRITON_CACHE_DIR="$TRITON_CACHE_DIR" MPLCONFIGDIR="$MPLCONFIGDIR" \
  FLASHINFER_WORKSPACE_DIR="$FLASHINFER_WORKSPACE_DIR" TORCHINDUCTOR_CACHE_DIR="$TORCHINDUCTOR_CACHE_DIR" CUDA_CACHE_PATH="$CUDA_CACHE_PATH" \
  A_VLLM_PYTHON="$A_VLLM_PYTHON" A_MODEL_PATH="$A_MODEL_PATH" A_PORT="$A_PORT" A_SERVED_MODEL="$A_SERVED_MODEL" \
  A_MAX_MODEL_LEN="$A_MAX_MODEL_LEN" A_MAX_NUM_SEQS="$A_MAX_NUM_SEQS" A_MAX_NUM_BATCHED_TOKENS="$A_MAX_NUM_BATCHED_TOKENS" \
  A_GPU_MEMORY_UTILIZATION="$A_GPU_MEMORY_UTILIZATION" A_CONTEXT_RAMP_SCHEDULE="$A_CONTEXT_RAMP_SCHEDULE" \
  A_LONG_PEAK_VRAM_MB="$A_LONG_PEAK_VRAM_MB" A_TELEMETRY_INTERVAL_SECONDS="$A_TELEMETRY_INTERVAL_SECONDS" \
  A_REQUEST_TIMEOUT_SECONDS="$A_REQUEST_TIMEOUT_SECONDS" A_VLLM_EXTRA_ARGS="${A_VLLM_EXTRA_ARGS:-}" \
  RUN_DIR="$RUN_DIR" \
  python -u /opt/ml-platform/context_ramp_eval.py "$RUN_DIR" > "$RUN_DIR/context_ramp.log" 2>&1 < /dev/null &

pid=$!
printf '%s\n' "$pid" > "$RUN_DIR/launcher.pid"
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/started_at"
echo "INCUMBENT_STARTED workload=context_ramp_eval pid=$pid run=$RUN_DIR"
