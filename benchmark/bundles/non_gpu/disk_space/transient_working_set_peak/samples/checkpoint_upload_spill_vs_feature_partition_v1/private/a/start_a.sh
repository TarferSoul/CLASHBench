#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
rm -rf "$A_RUNTIME_DIR"
mkdir -p "$A_RUNTIME_DIR"
chown -R agentb:agentb "$A_RUNTIME_DIR"
agent_uid=$(id -u agentb)
agent_gid=$(id -g agentb)
setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
  env -i HOME=/home/agentb USER=agentb LOGNAME=agentb \
  PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  "$A_TOOL" --root "$A_RUNTIME_DIR" --release "$A_RELEASE_FILE" --progress "$A_PROGRESS" \
  >>"$A_LOG" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$A_PID_FILE"
chown agentb:agentb "$A_PID_FILE"
for _ in $(seq 1 30); do
  [ -d "/proc/$pid" ] && [ "$(stat -c %u "/proc/$pid")" = "$agent_uid" ] && break
  sleep 0.05
done
[ -d "/proc/$pid" ]
[ "$(stat -c %u "/proc/$pid")" = "$agent_uid" ]
printf 'A_START_OK=1 pid=%s uid=%s role=checkpoint-multipart-publisher\n' "$pid" "$agent_uid"
