#!/bin/bash
# Start the two-tenant incumbent asynchronously and return its run directory.
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
mkdir -p "$RUN_DIR/alpha/adapter" "$RUN_DIR/beta/adapter" "$A_RUNS_ROOT"
ln -sfn "$RUN_DIR" "$A_RUNS_ROOT/current"

sed \
  -e "s|__OUTPUT_DIR__|$RUN_DIR/alpha/adapter|g" \
  -e "s|__DATASET__|$A_ALPHA_DATASET|g" \
  "$ROOT/a/tenant_alpha_lora.yaml.in" > "$RUN_DIR/alpha/train.yaml"
sed \
  -e "s|__OUTPUT_DIR__|$RUN_DIR/beta/adapter|g" \
  -e "s|__DATASET__|$A_BETA_DATASET|g" \
  "$ROOT/a/tenant_beta_lora.yaml.in" > "$RUN_DIR/beta/train.yaml"
cp "$ROOT/a/run_incumbent.sh" "$RUN_DIR/run_incumbent.sh"
chmod 755 "$RUN_DIR/run_incumbent.sh"
sha256sum "$A_ALPHA_DATA_FILE" "$A_BETA_DATA_FILE" "$RUN_DIR/alpha/train.yaml" "$RUN_DIR/beta/train.yaml" > "$RUN_DIR/inputs.sha256" 2>/dev/null || true

if id agentb >/dev/null 2>&1; then
  chown -R agentb:agentb "$A_RUNS_ROOT"
  cd "$RUN_DIR"
  setsid runuser -u agentb -- env HOME=/home/agentb PATH="$PATH" \
    LF_ROOT="$LF_ROOT" QWEN35_FASTPATH="$QWEN35_FASTPATH" RUN_DIR="$RUN_DIR" \
    OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}" CUDA_VISIBLE_DEVICES=0 \
    bash "$RUN_DIR/run_incumbent.sh" >/dev/null 2>&1 &
else
  setsid env LF_ROOT="$LF_ROOT" QWEN35_FASTPATH="$QWEN35_FASTPATH" RUN_DIR="$RUN_DIR" \
    OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}" CUDA_VISIBLE_DEVICES=0 \
    bash "$RUN_DIR/run_incumbent.sh" >/dev/null 2>&1 &
fi
pid=$!
printf '%s\n' "$pid" > "$RUN_DIR/launcher.pid"
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/started_at"
echo "A_STARTED mode=two_training_tenants launcher_pid=$pid run=$RUN_DIR"
