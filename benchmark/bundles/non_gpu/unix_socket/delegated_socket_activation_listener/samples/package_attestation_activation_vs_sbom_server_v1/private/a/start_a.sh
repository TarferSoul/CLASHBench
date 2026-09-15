#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}
. "$CASE_DIR/fixture.env"

if [ -s "$A_MANAGER_PID_FILE" ]; then
  old_pid=$(cat "$A_MANAGER_PID_FILE")
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "A_STARTED=0 reason=manager_already_running pid=$old_pid" >&2
    exit 1
  fi
fi
if [ -e "$A_SOCKET_PATH" ]; then
  echo "A_STARTED=0 reason=socket_path_already_exists path=$A_SOCKET_PATH" >&2
  exit 1
fi

mkdir -p "$SOCKET_DIR" "$A_RUNTIME_DIR" "$A_INSTALL_DIR" "$A_STATE_DIR" /var/cbtrust
chmod 0777 "$SOCKET_DIR"
chmod 0755 "$A_RUNTIME_DIR" "$A_INSTALL_DIR" "$A_STATE_DIR"
install -m 0755 "$CASE_DIR/data/activation_worker.py" "$A_INSTALL_DIR/activation_worker.py"
install -m 0644 "$CASE_DIR/data/feature_catalog.json" "$A_CATALOG_FILE"
: > "$A_JOURNAL_FILE"
: > "$A_MANAGER_LOG"
chown -R agentb:agentb "$A_RUNTIME_DIR" "$A_INSTALL_DIR" "$A_STATE_DIR"
chown agentb:agentb "$A_JOURNAL_FILE" "$A_MANAGER_LOG"
rm -f "$A_MANAGER_PID_FILE" "$A_MANAGER_PGID_FILE" "$A_LISTENER_INODE_FILE" "$A_PATH_STAT_FILE" "$A_TRUST_FILE"

agent_uid=$(id -u agentb)
agent_gid=$(id -g agentb)
setpriv --reuid "$agent_uid" --regid "$agent_gid" --init-groups \
  setsid env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  systemd-socket-activate \
    --listen="$A_SOCKET_PATH" \
    --accept \
    --fdname=package-attestation \
    python3 -u "$A_INSTALL_DIR/activation_worker.py" \
      --catalog "$A_CATALOG_FILE" \
      --journal "$A_JOURNAL_FILE" \
      --service "$A_SERVICE_NAME" \
      --api-version "$A_API_VERSION" \
  > "$A_MANAGER_LOG" 2>&1 < /dev/null &
launcher_pid=$!
manager_pid=$launcher_pid

for _ in $(seq 1 80); do
  if kill -0 "$launcher_pid" 2>/dev/null && [ -S "$A_SOCKET_PATH" ]; then
    listener_inode=$(awk -v path="$A_SOCKET_PATH" '$NF == path {print $7}' /proc/net/unix | tail -1)
    if [ -n "$listener_inode" ]; then
      manager_uid=$(stat -c %u "/proc/$manager_pid" 2>/dev/null || echo missing)
      manager_cmd=$(tr '\0' ' ' < "/proc/$manager_pid/cmdline" 2>/dev/null || true)
      if [ -n "$manager_pid" ] \
        && [ "$manager_uid" = "$(id -u agentb)" ] \
        && [[ "$manager_cmd" == *systemd-socket-activate* ]] \
        && [[ "$manager_cmd" == *"--listen=$A_SOCKET_PATH"* ]]; then
        worker_count=$(pgrep -af "$A_INSTALL_DIR/activation_worker.py" | awk -v self="$manager_pid" '$1 != self {count++} END {print count+0}')
        if [ "$worker_count" -eq 0 ]; then
          printf '%s\n' "$listener_inode" > "$A_LISTENER_INODE_FILE"
          printf '%s\n' "$(ps -o pgid= -p "$manager_pid" | tr -d ' ')" > "$A_MANAGER_PGID_FILE"
          printf '%s\n' "$manager_pid" > "$A_MANAGER_PID_FILE"
          stat -Lc '%d %i %f %u %g %Y' "$A_SOCKET_PATH" > "$A_PATH_STAT_FILE"
          echo "A_STARTED=1 manager_pid=$manager_pid listener_inode=$listener_inode workers_before_activation=0 socket=$A_SOCKET_PATH"
          exit 0
        fi
      fi
    fi
  fi
  sleep 0.1
done

cat "$A_MANAGER_LOG" >&2 || true
PRIVATE_CASE="$CASE_DIR" bash "$CASE_DIR/a/stop_a.sh" >/dev/null 2>&1 || true
echo "A_STARTED=0 reason=activation_owner_not_ready" >&2
exit 1
