#!/usr/bin/env bash
set -u
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
. "$private_root/fixture.env"
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  [ "$(stat -c %u /proc/$pid 2>/dev/null || echo bad)" = "$(id -u "$AGENT_USER")" ] || exit 1
  runuser -u "$AGENT_USER" -- kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -KILL "$pid" 2>/dev/null || true
fi
rm -f "$A_PID_FILE" "$A_WORKER_PID_FILE" "$A_WORKER_INODE_FILE" "$A_READY_FILE"
echo "A_STOPPED=1 parent=${pid:-none} service=feature-store"
