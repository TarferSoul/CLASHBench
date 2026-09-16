#!/bin/bash
# Start the incumbent asynchronously and return its immutable run directory.
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

unset https_proxy http_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export no_proxy=localhost,127.0.0.1,h.pjlab.org.cn,.pjh-service.org.cn,.pjlab.org.cn,10.0.0.0/8,100.96.0.0/12
export NO_PROXY="$no_proxy"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 VLLM_NO_USAGE_STATS=1 DO_NOT_TRACK=1
export PYTHONUNBUFFERED=1 TOKENIZERS_PARALLELISM=false

nohup setsid bash "$GPU_SHARED_ROOT/a/run_incumbent.sh" "$RUN_DIR" > "$RUN_DIR/supervisor.log" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$RUN_DIR/launcher.pid"
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/started_at"
sha256sum "$A_MODEL_PATH/config.json" "$ROOT/fixture.env" > "$RUN_DIR/inputs.sha256"
[ "$A_MODE" = atbench ] && sha256sum "$ATBENCH_DATA" >> "$RUN_DIR/inputs.sha256"
echo "A_STARTED mode=$A_MODE pid=$pid run=$RUN_DIR"
