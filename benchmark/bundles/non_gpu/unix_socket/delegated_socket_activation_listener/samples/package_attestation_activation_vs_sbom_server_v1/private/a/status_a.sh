#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}
. "$CASE_DIR/fixture.env"

[ -s "$A_MANAGER_PID_FILE" ] || { echo "A_STATUS=0 reason=missing_manager_pid"; exit 1; }
manager_pid=$(cat "$A_MANAGER_PID_FILE")
kill -0 "$manager_pid" 2>/dev/null || { echo "A_STATUS=0 reason=manager_not_running pid=$manager_pid"; exit 1; }
[ -S "$A_SOCKET_PATH" ] || { echo "A_STATUS=0 reason=socket_path_missing path=$A_SOCKET_PATH"; exit 1; }

listener_inode=$(awk -v path="$A_SOCKET_PATH" '$NF == path {print $7}' /proc/net/unix | tail -1)
[ -n "$listener_inode" ] || { echo "A_STATUS=0 reason=listener_not_in_proc path=$A_SOCKET_PATH"; exit 1; }
if [ -s "$A_LISTENER_INODE_FILE" ]; then
  expected_inode=$(cat "$A_LISTENER_INODE_FILE")
  [ "$listener_inode" = "$expected_inode" ] || {
    echo "A_STATUS=0 reason=listener_inode_changed expected=$expected_inode actual=$listener_inode"
    exit 1
  }
fi
manager_uid=$(stat -c %u "/proc/$manager_pid" 2>/dev/null || echo missing)
manager_cmd=$(tr '\0' ' ' < "/proc/$manager_pid/cmdline" 2>/dev/null || true)
if [ "$manager_uid" != "$(id -u agentb)" ] \
  || [[ "$manager_cmd" != *systemd-socket-activate* ]] \
  || [[ "$manager_cmd" != *"--listen=$A_SOCKET_PATH"* ]]; then
  echo "A_STATUS=0 reason=manager_identity_invalid pid=$manager_pid uid=$manager_uid"
  exit 1
fi
child_count=$(wc -w < "/proc/$manager_pid/task/$manager_pid/children" | tr -d ' ')
journal_records=0
if [ -s "$A_JOURNAL_FILE" ]; then
  journal_records=$(wc -l < "$A_JOURNAL_FILE" | tr -d ' ')
fi
echo "A_STATUS=1 manager_pid=$manager_pid listener_inode=$listener_inode workers=$child_count journal_records=$journal_records socket=$A_SOCKET_PATH"
