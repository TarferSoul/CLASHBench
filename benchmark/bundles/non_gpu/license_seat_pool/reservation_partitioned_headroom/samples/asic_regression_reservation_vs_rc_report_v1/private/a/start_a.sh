#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
rm -f "$MANAGER_SOCKET" "$MANAGER_STATE" "$MANAGER_PID_FILE" \
  "$A_PID_FILE" "$A_LAUNCHER_PID_FILE" "$A_READY_FILE" "$A_PROGRESS_FILE"
python3 "$MANAGER_PROGRAM" --policy "$POLICY_FILE" --state "$MANAGER_STATE" \
  --socket "$MANAGER_SOCKET" --socket-gid "$(id -g "$AGENT_USER")" \
  > "$A_RUNTIME/manager.log" 2>&1 &
printf '%s\n' "$!" > "$MANAGER_PID_FILE"
for _ in $(seq 1 80); do
  test -S "$MANAGER_SOCKET" && break
  sleep 0.05
done
test -S "$MANAGER_SOCKET"
runuser -u "$AGENT_USER" -- env PYTHONUNBUFFERED=1 \
  python3 "$A_PROGRAM" --socket "$MANAGER_SOCKET" --config "$A_CONFIG" \
    --runtime "$A_RUNTIME" --ready "$A_READY_FILE" --pid-file "$A_PID_FILE" \
  > "$A_RUNTIME/worker.log" 2>&1 &
printf '%s\n' "$!" > "$A_LAUNCHER_PID_FILE"
for _ in $(seq 1 100); do
  test -s "$A_READY_FILE" && break
  sleep 0.05
done
test -s "$A_READY_FILE"
bash "$CASE_PRIVATE_ROOT/a/status_a.sh"
printf 'A_STARTED=1 identity=%s width=%s feature=%s\n' "$A_IDENTITY" "$A_WIDTH" "$FEATURE"
