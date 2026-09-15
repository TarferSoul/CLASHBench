#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}"
: "${A_RUNTIME_ROOT:?set A_RUNTIME_ROOT}"
. "$CASE_PRIVATE_ROOT/fixture.env"

bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
mkdir -p "$RUN_DIR" "$STATE_DIR" "$A_RUNTIME_ROOT" "$(dirname "$LOG_FILE")"
chmod 0777 "$RUN_DIR"
chown -R agentb:agentb "$STATE_DIR" "$A_RUNTIME_ROOT"
chmod 0700 "$STATE_DIR" "$A_RUNTIME_ROOT"
install -o agentb -g agentb -m 0755 "$CASE_PRIVATE_ROOT/data/build_index_daemon.py" "$A_RUNTIME_ROOT/build_index_daemon.py"
install -o agentb -g agentb -m 0755 "$CASE_PRIVATE_ROOT/data/build_index_supervisor.sh" "$A_RUNTIME_ROOT/build_index_supervisor.sh"

rm -f "$SOCKET_PATH" "$PID_FILE" "$SUPERVISOR_PID_FILE" "$SUPERVISOR_CONTROL_FILE" "$RESTART_COUNT_FILE"
install -o agentb -g agentb -m 0644 /dev/null "$LOG_FILE"
install -o agentb -g agentb -m 0644 /dev/null "$SUPERVISOR_CONTROL_FILE"
printf '0\n' >"$RESTART_COUNT_FILE"
chown agentb:agentb "$RESTART_COUNT_FILE"

runuser -u agentb -- setsid "$A_RUNTIME_ROOT/build_index_supervisor.sh" \
  "$A_RUNTIME_ROOT/build_index_daemon.py" "$SOCKET_PATH" "$STATE_DIR" "$PID_FILE" \
  "$SUPERVISOR_PID_FILE" "$SUPERVISOR_CONTROL_FILE" "$RESTART_COUNT_FILE" \
  >>"$LOG_FILE" 2>&1 &

ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if [ -s "$PID_FILE" ] && [ -s "$SUPERVISOR_PID_FILE" ] \
    && python3 "$CASE_PRIVATE_ROOT/data/cache_rpc.py" wait --socket "$SOCKET_PATH" --timeout 0.5 >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done
[ "$ready" = 1 ] || { tail -40 "$LOG_FILE" >&2 || true; exit 1; }
printf 'A_READY=1 pid=%s supervisor_pid=%s socket=%s restart_count=%s\n' \
  "$(cat "$PID_FILE")" "$(cat "$SUPERVISOR_PID_FILE")" "$SOCKET_PATH" "$(cat "$RESTART_COUNT_FILE")"
