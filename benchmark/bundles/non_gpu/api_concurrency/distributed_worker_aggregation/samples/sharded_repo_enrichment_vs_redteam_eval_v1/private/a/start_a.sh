#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

mkdir -p /work
rm -rf "$A_RUNTIME_ROOT" "$A_STATE_ROOT"
install -d -o agentb -g agentb -m 700 "$A_RUNTIME_ROOT" "$A_STATE_ROOT"
install -o agentb -g agentb -m 700 "$ROOT/a/repo_enrichment_pipeline.py" "$A_RUNTIME_ROOT/repo_enrichment_pipeline.py"
install -o agentb -g agentb -m 600 "$ROOT/data/repo_enrichment_backlog.jsonl" "$A_BACKLOG_FILE"
rm -f "$A_PID_FILE"

runuser -u agentb -- setsid env -i HOME=/home/agentb USER=agentb LOGNAME=agentb \
  PATH="$FIXED_PATH" PYTHONUNBUFFERED=1 \
  python3 "$A_RUNTIME_ROOT/repo_enrichment_pipeline.py" \
    --endpoint "$CODE_ASSISTANT_EVAL_BASE_URL" \
    --model "$MODEL_ID" \
    --tenant "$TENANT_ID" \
    --owner-prefix "$A_OWNER_PREFIX" \
    --run-id "$A_RUN_ID" \
    --workers "$A_WORKERS" \
    --state-root "$A_STATE_ROOT" \
    --backlog-file "$A_BACKLOG_FILE" \
    --pid-file "$A_PID_FILE" \
    >"$A_RUNTIME_ROOT/repo_enrichment_pipeline.log" 2>&1 < /dev/null &
launcher_pid=$!

for _ in $(seq 1 240); do
  if [ -f "$A_PID_FILE" ] && bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    echo "A_STARTED=1 supervisor=$(cat "$A_PID_FILE") workers=$A_WORKERS tenant=$TENANT_ID active_min=$A_READY_ACTIVE_MIN"
    exit 0
  fi
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    cat "$A_RUNTIME_ROOT/repo_enrichment_pipeline.log" >&2 || true
    exit 1
  fi
  sleep 0.08
done

cat "$A_RUNTIME_ROOT/repo_enrichment_pipeline.log" >&2 || true
kill -TERM "-$launcher_pid" 2>/dev/null || kill -TERM "$launcher_pid" 2>/dev/null || true
echo "A readiness timeout" >&2
exit 1
