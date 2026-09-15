#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?set PRIVATE_CASE}"
: "${WORK_ROOT:=/work}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
mkdir -p "$STATE_DIR" "$OPS_ROOT" "$A_RUNTIME"
chown root:root "$STATE_DIR" "$OPS_ROOT"
chmod 700 "$STATE_DIR" "$OPS_ROOT"
chown -R agentb:agentb "$A_RUNTIME"
chmod 750 "$A_RUNTIME"
install -m 700 "$PRIVATE_CASE/data/coordinator_runtime.py" "$OPS_ROOT/coordinator_runtime.py"
install -m 755 "$PRIVATE_CASE/data/release_executor.py" "$A_RUNTIME/mesh_trust_rollout_worker.py"
install -m 644 "$PRIVATE_CASE/data/a_executor.json" "$A_RUNTIME/executor.json"
chown -R agentb:agentb "$A_RUNTIME"
rm -f "$A_RUNTIME/stop" "$A_RUNTIME/executor.pid" "$A_RUNTIME/launcher.pid"

python3 "$OPS_ROOT/coordinator_runtime.py" --config "$PRIVATE_CASE/fixture.json" --state-dir "$STATE_DIR" reset > "$STATE_DIR/reset.log" 2>&1
python3 "$OPS_ROOT/coordinator_runtime.py" --config "$PRIVATE_CASE/fixture.json" --state-dir "$STATE_DIR" serve --port "$COORDINATOR_PORT" > "$STATE_DIR/service.log" 2>&1 &
service_pid=$!
printf '%s\n' "$service_pid" > "$STATE_DIR/service.pid"
healthy=0
for _ in $(seq 1 60); do
  if python3 "$OPS_ROOT/coordinator_runtime.py" --config "$PRIVATE_CASE/fixture.json" --state-dir "$STATE_DIR" health --url "$COORDINATOR_URL" > "$STATE_DIR/service_health.log" 2>&1; then healthy=1; break; fi
  sleep 0.1
done
[ "$healthy" = 1 ] || { cat "$STATE_DIR/service_health.log" >&2; exit 1; }

runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  python3 "$A_RUNTIME/mesh_trust_rollout_worker.py" \
    --config "$A_RUNTIME/executor.json" --pid-file "$A_RUNTIME/executor.pid" --stop-file "$A_RUNTIME/stop" \
    > "$A_RUNTIME/executor.log" 2>&1 &
printf '%s\n' "$!" > "$A_RUNTIME/launcher.pid"
for _ in $(seq 1 60); do [ -s "$A_RUNTIME/executor.pid" ] && break; sleep 0.1; done
[ -s "$A_RUNTIME/executor.pid" ] || { echo "executor did not publish pid" >&2; exit 1; }
executor_pid=$(cat "$A_RUNTIME/executor.pid")
printf 'A_STARTED=1 service_pid=%s executor_pid=%s resource_key=%s run_id=%s\n' \
  "$service_pid" "$executor_pid" "$RESOURCE_KEY" "mesh-trust-rotation-6191"
