#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
agent_uid=${AGENT_UID:-$(id -u agentb)}
agent_gid=${AGENT_GID:-$(id -g agentb)}
if ! curl --noproxy '*' -fsS "http://$GATEWAY_HOST:$GATEWAY_PORT/healthz" >/dev/null 2>&1; then
  CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/start_platform.sh"
fi
rm -rf "$A_RUNTIME_ROOT" "$(dirname "$A_PROGRESS_FILE")"
install -d -o "$agent_uid" -g "$agent_gid" -m 0755 "$A_RUNTIME_ROOT" "$(dirname "$A_PROGRESS_FILE")"
install -o "$agent_uid" -g "$agent_gid" -m 0755 "$ROOT/data/incumbent.py" "$A_RUNTIME_ROOT/run_monitor.py"
install -o "$agent_uid" -g "$agent_gid" -m 0644 "$ROOT/data/incumbent_cases.json" "$A_RUNTIME_ROOT/contracts.json"
setpriv --reuid "$agent_uid" --regid "$agent_gid" --init-groups --reset-env \
  env HOME=/home/agentb USER=agentb LOGNAME=agentb PATH=/usr/local/bin:/usr/bin:/bin \
  python3 "$A_RUNTIME_ROOT/run_monitor.py" \
    --url "http://$GATEWAY_HOST:$GATEWAY_PORT$GATEWAY_PATH" --tenant "$TENANT_ID" \
    --model "$MODEL_ID" --owner "$A_OWNER" --workers "$A_WORKERS" \
    --cases "$A_RUNTIME_ROOT/contracts.json" --progress "$A_PROGRESS_FILE" --results "$A_RESULTS_FILE" \
  >"$A_RUNTIME_ROOT/monitor.log" 2>&1 &
incumbent_pid=$!
printf '%s\n' "$incumbent_pid" >"$A_PID_FILE"
sleep 0.1
kill -0 "$incumbent_pid"
[ "$(stat -Lc %u "/proc/$incumbent_pid")" = "$agent_uid" ]
echo "A_STARTED=1 incumbent_pid=$incumbent_pid agent_uid=$agent_uid workers=$A_WORKERS"

