#!/bin/bash
# Start the incumbent service asynchronously and return its run directory.
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

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
mkdir -p "$RUN_DIR" "$A_RUNS_ROOT"
ln -sfn "$RUN_DIR" "$A_RUNS_ROOT/current"

cp "$ROOT/a/run_incumbent.sh" "$RUN_DIR/service_runner.sh"
cp "$ROOT/data/structured_chat_template.jinja" "$RUN_DIR/structured_chat_template.jinja"
chmod 755 "$RUN_DIR/service_runner.sh"
chown -R agentb:agentb "$RUN_DIR" "$A_RUNS_ROOT"

unset https_proxy http_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export no_proxy=localhost,127.0.0.1,h.pjlab.org.cn,.pjh-service.org.cn,.pjlab.org.cn,10.0.0.0/8,100.96.0.0/12
export NO_PROXY="$no_proxy"

cd "$RUN_DIR"
setsid runuser -u agentb -- env \
  HOME=/home/agentb \
  PATH="/opt/node/bin:/opt/conda/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1 \
  PYTHONUNBUFFERED=1 TOKENIZERS_PARALLELISM=false \
  RUN_DIR="$RUN_DIR" \
  A_VLLM_PYTHON="$A_VLLM_PYTHON" \
  A_MODEL_PATH="$A_MODEL_PATH" \
  A_PORT="$A_PORT" \
  A_SERVED_MODEL="$A_SERVED_MODEL" \
  A_CHAT_TEMPLATE="$RUN_DIR/structured_chat_template.jinja" \
  A_MAX_MODEL_LEN="$A_MAX_MODEL_LEN" \
  A_MAX_NUM_SEQS="$A_MAX_NUM_SEQS" \
  A_MAX_NUM_BATCHED_TOKENS="$A_MAX_NUM_BATCHED_TOKENS" \
  A_GPU_MEMORY_UTILIZATION="$A_GPU_MEMORY_UTILIZATION" \
  bash "$RUN_DIR/service_runner.sh" >/dev/null 2>&1 &

pid=$!
printf '%s\n' "$pid" > "$RUN_DIR/launcher.pid"
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/started_at"
sha256sum "$A_MODEL_PATH/config.json" "$ROOT/fixture.env" "$ROOT/data/structured_canary.json" > "$RUN_DIR/inputs.sha256" 2>/dev/null || true
echo "A_STARTED service=structured_json pid=$pid run=$RUN_DIR"
