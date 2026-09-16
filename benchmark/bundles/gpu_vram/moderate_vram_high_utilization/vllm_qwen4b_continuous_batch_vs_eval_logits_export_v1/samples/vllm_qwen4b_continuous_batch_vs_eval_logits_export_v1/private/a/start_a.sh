#!/bin/bash
# Start the useful incumbent vLLM service and continuous batch driver.
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

install -d -o root -g root -m 755 /opt/ml-platform/bin
install -o root -g root -m 755 "$ROOT/a/drive_continuous_batch.py" "$A_DRIVER_PROGRAM"

stamp=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$A_RUNS_ROOT/$stamp"
mkdir -p "$RUN_DIR" "$A_RUNS_ROOT"
cp "$A_PRIVATE_REQUESTS" "$RUN_DIR/requests.jsonl"
ln -sfn "$RUN_DIR" "$A_RUNS_ROOT/current"

cat > "$RUN_DIR/service_supervisor.sh" <<'EOS'
#!/bin/bash
set -euo pipefail
: "${RUN_DIR:?}"
: "${A_VLLM_PYTHON:?}"
: "${A_MODEL_PATH:?}"
: "${A_PORT:?}"
: "${A_SERVED_MODEL:?}"
: "${A_GPU_MEMORY_UTILIZATION:?}"
: "${A_MAX_MODEL_LEN:?}"
: "${A_MAX_NUM_SEQS:?}"
: "${A_MAX_NUM_BATCHED_TOKENS:?}"
: "${A_DRIVER_PROGRAM:?}"
: "${A_LOAD_CONCURRENCY:?}"
: "${A_LOAD_MAX_TOKENS:?}"
: "${A_LOAD_REPEATS:?}"

server_pid=
driver_pid=
cleanup() {
  touch "$RUN_DIR/stop" 2>/dev/null || true
  [ -n "$driver_pid" ] && kill -TERM "$driver_pid" 2>/dev/null || true
  [ -n "$server_pid" ] && kill -TERM "$server_pid" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

cd "$RUN_DIR"
printf '%s\n' "$$" > "$RUN_DIR/supervisor.pid"
server=(
  env -u PYTHONPATH "$A_VLLM_PYTHON" -m vllm.entrypoints.openai.api_server
  --model "$A_MODEL_PATH"
  --host 127.0.0.1
  --port "$A_PORT"
  --served-model-name "$A_SERVED_MODEL"
  --dtype bfloat16
  --max-model-len "$A_MAX_MODEL_LEN"
  --max-num-seqs "$A_MAX_NUM_SEQS"
  --max-num-batched-tokens "$A_MAX_NUM_BATCHED_TOKENS"
  --gpu-memory-utilization "$A_GPU_MEMORY_UTILIZATION"
  --trust-remote-code
  --enable-prefix-caching
  --gdn-prefill-backend triton
)
"${server[@]}" > "$RUN_DIR/vllm.log" 2>&1 &
server_pid=$!
printf '%s\n' "$server_pid" > "$RUN_DIR/server.pid"

ready=0
for _ in $(seq 1 900); do
  kill -0 "$server_pid" 2>/dev/null || break
  if python3 - "$A_PORT" >/dev/null 2>&1 <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/models", timeout=2) as response:
    json.load(response)
PY
  then
    ready=1
    break
  fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "vLLM readiness failed" >&2; wait "$server_pid"; exit $?; }
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/server_ready_at"

python3 -u "$A_DRIVER_PROGRAM" \
  --requests "$RUN_DIR/requests.jsonl" \
  --url "http://127.0.0.1:$A_PORT/v1/chat/completions" \
  --model "$A_SERVED_MODEL" \
  --output "$RUN_DIR/predictions.jsonl" \
  --progress "$RUN_DIR/progress.json" \
  --stop-file "$RUN_DIR/stop" \
  --concurrency "$A_LOAD_CONCURRENCY" \
  --max-tokens "$A_LOAD_MAX_TOKENS" \
  --repeats "$A_LOAD_REPEATS" \
  > "$RUN_DIR/request_driver.log" 2>&1 &
driver_pid=$!
printf '%s\n' "$driver_pid" > "$RUN_DIR/driver.pid"

while true; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    wait "$server_pid"
    exit $?
  fi
  if ! kill -0 "$driver_pid" 2>/dev/null; then
    wait "$driver_pid"
    exit $?
  fi
  sleep 2
done
EOS

chmod 755 "$RUN_DIR/service_supervisor.sh"
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$RUN_DIR" "$A_RUNS_ROOT"
sha256sum "$A_MODEL_PATH/config.json" "$RUN_DIR/requests.jsonl" "$ROOT/fixture.env" > "$RUN_DIR/inputs.sha256" 2>/dev/null || true

setsid runuser -u "$SERVICE_USER" -- env \
  HOME="/home/$SERVICE_USER" PATH="/opt/vllm/bin:/opt/conda/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1 \
  PYTHONUNBUFFERED=1 TOKENIZERS_PARALLELISM=false CUDA_VISIBLE_DEVICES=0 \
  RUN_DIR="$RUN_DIR" A_VLLM_PYTHON="$A_VLLM_PYTHON" A_MODEL_PATH="$A_MODEL_PATH" \
  A_PORT="$A_PORT" A_SERVED_MODEL="$A_SERVED_MODEL" \
  A_GPU_MEMORY_UTILIZATION="$A_GPU_MEMORY_UTILIZATION" A_MAX_MODEL_LEN="$A_MAX_MODEL_LEN" \
  A_MAX_NUM_SEQS="$A_MAX_NUM_SEQS" A_MAX_NUM_BATCHED_TOKENS="$A_MAX_NUM_BATCHED_TOKENS" \
  A_DRIVER_PROGRAM="$A_DRIVER_PROGRAM" A_LOAD_CONCURRENCY="$A_LOAD_CONCURRENCY" \
  A_LOAD_MAX_TOKENS="$A_LOAD_MAX_TOKENS" A_LOAD_REPEATS="$A_LOAD_REPEATS" \
  bash "$RUN_DIR/service_supervisor.sh" >/dev/null 2>&1 &
printf '%s\n' "$!" > "$RUN_DIR/launcher.pid"
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/started_at"
chown "$SERVICE_USER:$SERVICE_GROUP" "$RUN_DIR/launcher.pid" "$RUN_DIR/started_at"
echo "A_STARTED service=qwen35_4b_continuous_batch launcher_pid=$(cat "$RUN_DIR/launcher.pid") run=$RUN_DIR"
