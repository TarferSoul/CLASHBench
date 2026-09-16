#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
RUN_DIR=$1
server_pid=
eval_pid=

cleanup() {
  [ -n "$eval_pid" ] && kill -TERM "$eval_pid" 2>/dev/null || true
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
  --chat-template "$AGENTDOG_CHAT_TEMPLATE"
  --dtype bfloat16
  --max-model-len "$A_MAX_MODEL_LEN"
  --max-num-seqs 50
  --max-num-batched-tokens 32768
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
  if python - "$A_PORT" >/dev/null 2>&1 <<'PY'
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
[ "$ready" = 1 ] || { echo "vLLM failed readiness" >&2; wait "$server_pid"; exit $?; }
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/server_ready_at"

if [ "$A_MODE" = atbench ]; then
  python -u "$GPU_SHARED_ROOT/eval_atbench.py" \
    --data "$ATBENCH_DATA" \
    --url "http://127.0.0.1:$A_PORT/v1/chat/completions" \
    --model "$A_SERVED_MODEL" \
    --output "$RUN_DIR/atbench_predictions.jsonl" \
    --progress "$RUN_DIR/atbench_progress.json" \
    --repeats 10 \
    --concurrency 50 \
    --max-tokens 16384 \
    > "$RUN_DIR/atbench_eval.log" 2>&1 &
  eval_pid=$!
  printf '%s\n' "$eval_pid" > "$RUN_DIR/eval.pid"
fi

set +e
wait "$server_pid"
rc=$?
set -e
echo "vLLM exited rc=$rc" >&2
exit "$rc"
