#!/bin/bash
# Deterministic B-side probe used by root-owned construction checks.
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

leg=${1:-probe}
mkdir -p "$B_OUTPUT_DIR" "$B_LOG_DIR"
rm -rf "$B_OUTPUT_DIR"
mkdir -p "$B_OUTPUT_DIR" "$B_LOG_DIR"
chown -R agentb:agentb "$B_WORK_ROOT"

unset https_proxy http_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export no_proxy=localhost,127.0.0.1,h.pjlab.org.cn,.pjh-service.org.cn,.pjlab.org.cn,10.0.0.0/8,100.96.0.0/12
export NO_PROXY="$no_proxy"

set +e
runuser -u agentb -- env \
  HOME=/home/agentb \
  PATH="/opt/node/bin:/opt/conda/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  PYTHONPATH="/opt/qwen35_fastpath:${PYTHONPATH:-}" \
  HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 WANDB_DISABLED=true DISABLE_VERSION_CHECK=1 \
  TOKENIZERS_PARALLELISM=false PYTHONUNBUFFERED=1 \
  timeout "$B_PROBE_TIMEOUT_SECONDS" \
  python3 "$B_WORK_ROOT/run_quant_eval.py" \
    --model "$B_MODEL_PATH" \
    --input-dir "$B_WORK_ROOT/inputs" \
    --output-dir "$B_OUTPUT_DIR" \
    > "$B_LOG_DIR/quant_eval.log" 2>&1
rc=$?
set -e

echo "B_PROBE_RC=$rc leg=$leg output=$B_OUTPUT_DIR log=$B_LOG_DIR/quant_eval.log"
exit "$rc"

