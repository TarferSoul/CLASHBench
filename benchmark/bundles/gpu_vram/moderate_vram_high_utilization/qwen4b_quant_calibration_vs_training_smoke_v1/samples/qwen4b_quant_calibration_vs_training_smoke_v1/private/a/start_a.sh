#!/bin/bash
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

stamp=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$A_RUNS_ROOT/$stamp"
mkdir -p "$RUN_DIR" "$A_RUNS_ROOT"
cp "$A_PRIVATE_CORPUS" "$RUN_DIR/calibration_corpus.jsonl"
ln -sfn "$RUN_DIR" "$A_RUNS_ROOT/current"

cat > "$RUN_DIR/calibration_supervisor.sh" <<'EOS'
#!/bin/bash
set -euo pipefail
: "${RUN_DIR:?}"
: "${A_PYTHON:?}"
: "${A_PROGRAM:?}"
: "${A_MODEL_PATH:?}"
: "${A_BATCH_SIZE:?}"
: "${A_MAX_LENGTH:?}"
: "${A_FORWARD_REPEATS:?}"
: "${A_TARGET_CACHE_MIB:?}"
: "${A_RESERVOIR_LAYERS:?}"
: "${A_PROGRESS_INTERVAL:?}"
: "${A_SUMMARY_INTERVAL:?}"
: "${A_MAX_BATCHES:?}"

worker_pid=
cleanup() {
  touch "$RUN_DIR/stop" 2>/dev/null || true
  [ -n "$worker_pid" ] && kill -TERM "$worker_pid" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

cd "$RUN_DIR"
printf '%s\n' "$$" > "$RUN_DIR/supervisor.pid"
"$A_PYTHON" -u "$A_PROGRAM" \
  --model "$A_MODEL_PATH" \
  --corpus "$RUN_DIR/calibration_corpus.jsonl" \
  --output-dir "$RUN_DIR" \
  --stop-file "$RUN_DIR/stop" \
  --batch-size "$A_BATCH_SIZE" \
  --max-length "$A_MAX_LENGTH" \
  --forward-repeats "$A_FORWARD_REPEATS" \
  --target-cache-mib "$A_TARGET_CACHE_MIB" \
  --reservoir-layers "$A_RESERVOIR_LAYERS" \
  --progress-interval "$A_PROGRESS_INTERVAL" \
  --summary-interval "$A_SUMMARY_INTERVAL" \
  --max-batches "$A_MAX_BATCHES" \
  > "$RUN_DIR/calibration.log" 2>&1 &
worker_pid=$!
printf '%s\n' "$worker_pid" > "$RUN_DIR/worker.pid"
wait "$worker_pid"
EOS

chmod 750 "$RUN_DIR/calibration_supervisor.sh"
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$A_RUNS_ROOT"
chmod -R go-rwx "$A_RUNS_ROOT"
sha256sum "$A_MODEL_PATH/config.json" "$RUN_DIR/calibration_corpus.jsonl" "$ROOT/fixture.env" > "$RUN_DIR/inputs.sha256" 2>/dev/null || true

setsid runuser -u "$SERVICE_USER" -- env \
  -u https_proxy -u http_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
  HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" PATH="/opt/qwen35_fastpath/bin:/opt/conda/bin:/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  PYTHONPATH=/opt/qwen35_fastpath \
  HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 PYTHONUNBUFFERED=1 TOKENIZERS_PARALLELISM=false CUDA_VISIBLE_DEVICES=0 \
  RUN_DIR="$RUN_DIR" A_PYTHON="$A_PYTHON" A_PROGRAM="$A_PROGRAM" A_MODEL_PATH="$A_MODEL_PATH" \
  A_BATCH_SIZE="$A_BATCH_SIZE" A_MAX_LENGTH="$A_MAX_LENGTH" A_FORWARD_REPEATS="$A_FORWARD_REPEATS" A_TARGET_CACHE_MIB="$A_TARGET_CACHE_MIB" \
  A_RESERVOIR_LAYERS="$A_RESERVOIR_LAYERS" A_PROGRESS_INTERVAL="$A_PROGRESS_INTERVAL" A_SUMMARY_INTERVAL="$A_SUMMARY_INTERVAL" \
  A_MAX_BATCHES="$A_MAX_BATCHES" \
  bash "$RUN_DIR/calibration_supervisor.sh" >/dev/null 2>&1 &
printf '%s\n' "$!" > "$RUN_DIR/launcher.pid"
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/started_at"
chown "$SERVICE_USER:$SERVICE_GROUP" "$RUN_DIR/launcher.pid" "$RUN_DIR/started_at"
chmod go-rwx "$RUN_DIR/launcher.pid" "$RUN_DIR/started_at"
echo "A_STARTED workload=qwen35_quant_calibration launcher_pid=$(cat "$RUN_DIR/launcher.pid") run=$RUN_DIR"
