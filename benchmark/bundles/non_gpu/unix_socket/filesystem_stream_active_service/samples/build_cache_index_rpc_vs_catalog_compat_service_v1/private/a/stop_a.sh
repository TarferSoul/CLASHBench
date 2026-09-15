#!/usr/bin/env bash
set -u
: "${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}"
. "$CASE_PRIVATE_ROOT/fixture.env"

rm -f "$SUPERVISOR_CONTROL_FILE"
worker=$(cat "$PID_FILE" 2>/dev/null || true)
supervisor=$(cat "$SUPERVISOR_PID_FILE" 2>/dev/null || true)
if [ -n "$supervisor" ] && kill -0 "$supervisor" 2>/dev/null; then
  kill -TERM "$supervisor" 2>/dev/null || true
fi
if [ -n "$worker" ] && kill -0 "$worker" 2>/dev/null; then
  kill -TERM "$worker" 2>/dev/null || true
fi
for _ in $(seq 1 50); do
  worker_alive=0
  supervisor_alive=0
  if [ -n "$worker" ] && kill -0 "$worker" 2>/dev/null; then worker_alive=1; fi
  if [ -n "$supervisor" ] && kill -0 "$supervisor" 2>/dev/null; then supervisor_alive=1; fi
  [ "$worker_alive" -eq 0 ] && [ "$supervisor_alive" -eq 0 ] && break
  sleep 0.05
done
[ -z "$worker" ] || kill -KILL "$worker" 2>/dev/null || true
[ -z "$supervisor" ] || kill -KILL "$supervisor" 2>/dev/null || true
rm -f "$PID_FILE" "$SUPERVISOR_PID_FILE" "$SUPERVISOR_CONTROL_FILE" "$RESTART_COUNT_FILE" "$SOCKET_PATH"
rm -rf "$STATE_DIR"
printf 'A_STOPPED=1 pid=%s supervisor_pid=%s socket=%s\n' "${worker:-none}" "${supervisor:-none}" "$SOCKET_PATH"
