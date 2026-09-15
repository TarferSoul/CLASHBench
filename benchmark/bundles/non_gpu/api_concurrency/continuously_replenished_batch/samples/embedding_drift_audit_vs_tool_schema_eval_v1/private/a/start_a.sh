#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/api_case/private/case}
. "$ROOT/fixture.env"

bash "$ROOT/platform/status_gateway.sh" >/dev/null
rm -rf "$A_RUNTIME_ROOT"
install -d -m 700 "$A_RUNTIME_ROOT" "$A_STATE_ROOT"
install -m 700 "$ROOT/a/audit_batch.py" "$A_RUNTIME_ROOT/audit_batch.py"
install -m 600 "$ROOT/data/$A_CASE_FILE" "$A_RUNTIME_ROOT/a_cases.json"
chown -R agentb:agentb "$A_RUNTIME_ROOT"

runuser -u agentb -- setsid env -i HOME=/home/agentb USER=agentb LOGNAME=agentb PATH="$FIXED_PATH" \
  python3 "$A_RUNTIME_ROOT/audit_batch.py" \
    --endpoint "http://$A_HOST:$A_PORT/v1/classify" --model "$MODEL_ID" \
    --workers "$A_WORKERS" --revisions "$A_PROMPT_REVISIONS" \
    --state-root "$A_STATE_ROOT" --cases-file "$A_RUNTIME_ROOT/a_cases.json" \
    --pid-file "$A_PID_FILE" >"$A_RUNTIME_ROOT/audit.log" 2>&1 < /dev/null &
launcher_pid=$!

for _ in $(seq 1 180); do
  if [ -s "$A_PID_FILE" ] && bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    echo "A_STARTED=1 supervisor=$(cat "$A_PID_FILE") workers=$A_WORKERS model=$MODEL_ID output=$A_STATE_ROOT"
    exit 0
  fi
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    cat "$A_RUNTIME_ROOT/audit.log" >&2 || true
    exit 1
  fi
  sleep 0.05
done
cat "$A_RUNTIME_ROOT/audit.log" >&2 || true
kill -TERM "$launcher_pid" 2>/dev/null || true
echo "embedding drift audit readiness timeout" >&2
exit 1
