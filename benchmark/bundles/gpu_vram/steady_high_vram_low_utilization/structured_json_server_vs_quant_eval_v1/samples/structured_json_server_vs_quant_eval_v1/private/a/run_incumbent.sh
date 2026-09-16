#!/bin/bash
# Long-lived structured-output model service. The launcher copies this file
# into the service run directory before execution.
set -euo pipefail

: "${RUN_DIR:?}"
: "${A_VLLM_PYTHON:?}"
: "${A_MODEL_PATH:?}"
: "${A_PORT:?}"
: "${A_SERVED_MODEL:?}"
: "${A_CHAT_TEMPLATE:?}"
: "${A_MAX_MODEL_LEN:?}"
: "${A_MAX_NUM_SEQS:?}"
: "${A_MAX_NUM_BATCHED_TOKENS:?}"
: "${A_GPU_MEMORY_UTILIZATION:?}"

server_pid=

cleanup() {
  [ -n "$server_pid" ] && kill -TERM "$server_pid" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

printf '%s\n' "$$" > "$RUN_DIR/supervisor.pid"

server=(
  env -u PYTHONPATH "$A_VLLM_PYTHON" -m vllm.entrypoints.openai.api_server
  --model "$A_MODEL_PATH"
  --host 127.0.0.1
  --port "$A_PORT"
  --served-model-name "$A_SERVED_MODEL"
  --chat-template "$A_CHAT_TEMPLATE"
  --dtype bfloat16
  --max-model-len "$A_MAX_MODEL_LEN"
  --max-num-seqs "$A_MAX_NUM_SEQS"
  --max-num-batched-tokens "$A_MAX_NUM_BATCHED_TOKENS"
  --gpu-memory-utilization "$A_GPU_MEMORY_UTILIZATION"
  --trust-remote-code
  --enable-prefix-caching
  --reasoning-parser qwen3
  --language-model-only
  --gdn-prefill-backend triton
)

"${server[@]}" > "$RUN_DIR/vllm.log" 2>&1 &
server_pid=$!
printf '%s\n' "$server_pid" > "$RUN_DIR/server.pid"

ready=0
for _ in $(seq 1 900); do
  kill -0 "$server_pid" 2>/dev/null || break
  if python3 - "$A_PORT" >/dev/null 2>&1 <<'PY'
import json
import sys
import urllib.request

with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/v1/models", timeout=2) as response:
    json.load(response)
PY
  then
    ready=1
    break
  fi
  sleep 1
done

[ "$ready" = 1 ] || { echo "structured vLLM service failed readiness" >&2; wait "$server_pid"; exit $?; }
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/server_ready_at"

set +e
wait "$server_pid"
rc=$?
set -e
echo "structured vLLM service exited rc=$rc" >&2
exit "$rc"

