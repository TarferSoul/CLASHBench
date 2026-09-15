#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
. "$private_root/fixture.env"
agent_uid=$(id -u "$AGENT_USER")
agent_gid=$(id -g "$AGENT_USER")
[ "$agent_uid" -gt 0 ] || exit 1
install -d -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$A_RUNTIME_DIR" "$A_STATE_DIR"
install -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$private_root/data/activation_parent.py" "$A_RUNTIME_DIR/activation_parent.py"
install -m 0755 -o "$AGENT_USER" -g "$AGENT_USER" "$private_root/data/feature_worker.py" "$A_RUNTIME_DIR/feature_worker.py"
rm -f "$A_STATE_DIR"/*
: >"$A_LOG_FILE"
chown "$AGENT_USER:$AGENT_USER" "$A_LOG_FILE"
setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- \
  env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 PYTHONUNBUFFERED=1 \
  python3 "$A_RUNTIME_DIR/activation_parent.py" --address "$LISTEN_ADDRESS" --port "$LISTEN_PORT" \
    --runtime "$A_RUNTIME_DIR" --state "$A_STATE_DIR" --service feature-store \
  >>"$A_LOG_FILE" 2>&1 &
parent_pid=$!
printf '%s\n' "$parent_pid" >"$A_PID_FILE"
chown "$AGENT_USER:$AGENT_USER" "$A_PID_FILE"
for _ in $(seq 1 60); do
  if [ -s "$A_READY_FILE" ] && kill -0 "$parent_pid" 2>/dev/null && [ ! -e "$A_WORKER_PID_FILE" ]; then
    [ "$(stat -c %u /proc/$parent_pid)" = "$agent_uid" ] || exit 1
    runuser -u "$AGENT_USER" -- kill -0 "$parent_pid"
    printf 'A_STARTED=1 parent_pid=%s parent_uid=%s endpoint=%s:%s worker_before_activation=absent listener_inode=%s\n' \
      "$parent_pid" "$(stat -c %u /proc/$parent_pid)" "$LISTEN_ADDRESS" "$LISTEN_PORT" "$(cat "$A_INODE_FILE")"
    exit 0
  fi
  sleep 0.1
done
cat "$A_LOG_FILE" >&2 || true
kill "$parent_pid" 2>/dev/null || true
exit 1
