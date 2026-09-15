#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/lane_eval/private/case}
. "$ROOT/fixture.env"

id agentb >/dev/null
command -v setpriv >/dev/null
rm -rf "$A_RUNTIME_ROOT"
mkdir -p "$A_RUNTIME_ROOT"
install -o agentb -g agentb -m 700 "$ROOT/a/incumbent.py" "$A_RUNTIME_ROOT/client.py"
touch "$A_RUNTIME_ROOT/state.json" "$A_RUNTIME_ROOT/checkpoints.jsonl"
chown agentb:agentb "$A_RUNTIME_ROOT" "$A_RUNTIME_ROOT/state.json" "$A_RUNTIME_ROOT/checkpoints.jsonl"
chmod 700 "$A_RUNTIME_ROOT"
agent_uid=$(id -u agentb)
agent_gid=$(id -g agentb)
endpoint="http://$A_HOST:$A_PORT/v1/responses"
[ "$RESPONSE_MODE" = schema ] || endpoint="http://$A_HOST:$A_PORT/v1/judge"
setpriv --reuid "$agent_uid" --regid "$agent_gid" --init-groups -- \
  setsid python3 "$A_RUNTIME_ROOT/client.py" \
    --endpoint "$endpoint" --deployment "$TARGET_DEPLOYMENT" --owner "$A_OWNER_TAG" \
    --workers "$A_WORKERS" --mode "$RESPONSE_MODE" \
    --state "$A_RUNTIME_ROOT/state.json" --output "$A_RUNTIME_ROOT/checkpoints.jsonl" \
    >"$A_RUNTIME_ROOT/stdout.log" 2>"$A_RUNTIME_ROOT/stderr.log" &
incumbent_pid=$!
printf '%s\n' "$incumbent_pid" >"$A_RUNTIME_ROOT/incumbent.pid"
chown root:root "$A_RUNTIME_ROOT/incumbent.pid"
chmod 600 "$A_RUNTIME_ROOT/incumbent.pid"

ready=0
for _ in $(seq 1 180); do
  if python3 - "$incumbent_pid" "$agent_uid" "$A_RUNTIME_ROOT/state.json" \
    "$GATEWAY_STATE" "$TARGET_DEPLOYMENT" "$A_OWNER_TAG" "$A_WORKERS" <<'PY' >/dev/null 2>&1
import json, os, pathlib, sys
pid, uid, state_path, gateway_path, deployment, owner, workers = (
    int(sys.argv[1]), int(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4]),
    sys.argv[5], sys.argv[6], int(sys.argv[7])
)
os.kill(pid, 0)
assert pathlib.Path(f"/proc/{pid}").stat().st_uid == uid
state = json.loads(state_path.read_text())
gateway = json.loads(gateway_path.read_text())
assert state["pid"] == pid and state["deployment"] == deployment and state["owner"] == owner
assert state["completed"] >= workers
assert gateway["active_by_deployment"].get(deployment, 0) == workers
assert gateway["active_by_owner"].get(f"{deployment}|{owner}", 0) == workers
PY
  then
    ready=1
    break
  fi
  sleep .05
done
[ "$ready" = 1 ]
echo "A_READY=1 pid=$incumbent_pid uid=$agent_uid deployment=$TARGET_DEPLOYMENT workers=$A_WORKERS"
