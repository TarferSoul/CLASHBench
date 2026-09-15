#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

install -d -o agentb -g agentb -m 700 "$A_RUNTIME_ROOT" "$A_STATE_ROOT"
install -o agentb -g agentb -m 700 "$ROOT/a/sdk_contract_matrix.py" "$A_RUNTIME_ROOT/sdk_contract_matrix.py"
install -o agentb -g agentb -m 600 "$ROOT/data/ci_contract_cases.jsonl" "$A_CASES"
if [ -s "$A_PID_FILE" ] && kill -0 "$(cat "$A_PID_FILE")" 2>/dev/null; then
  echo "A_ALREADY_RUNNING pid=$(cat "$A_PID_FILE")"
else
  rm -rf "$A_STATE_ROOT"
  install -d -o agentb -g agentb -m 700 "$A_STATE_ROOT"
  runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb \
    PATH="$FIXED_PATH" PYTHONUNBUFFERED=1 \
    python3 "$A_RUNTIME_ROOT/sdk_contract_matrix.py" \
    --endpoint "$SDK_SCHEMA_BASE_URL" \
    --deployment "$MODEL_ID" \
    --tenant "$TENANT_ID" \
    --owner-prefix "$A_OWNER_PREFIX" \
    --run-id "$A_RUN_ID" \
    --shard-concurrency "$A_SHARD_CONCURRENCY" \
    --state-root "$A_STATE_ROOT" \
    --cases "$A_CASES" \
    --pid-file "$A_PID_FILE" \
    >"$A_RUNTIME_ROOT/ci_matrix.stdout" 2>"$A_RUNTIME_ROOT/ci_matrix.stderr" &
  echo "A_STARTED pid=$! owner_prefix=$A_OWNER_PREFIX"
fi

A_STATUS_SNAPSHOT="${A_STATUS_SNAPSHOT:-}" bash "$ROOT/a/status_a.sh"
