#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/lib/common.sh"

[ -s "$A_PID_FILE" ] || exit 1
pid=$(cat "$A_PID_FILE")
case "$pid" in *[!0-9]*|'') exit 1 ;; esac
kill -0 "$pid" 2>/dev/null || exit 1
agent_uid=$(id -u "$AGENT_USER")
uid=$(pid_uid "$pid")
[ "$uid" = "$agent_uid" ] || exit 1
runuser -u "$AGENT_USER" -- kill -0 "$pid" || exit 1
start_time=$(pid_start_time "$pid")
inode=$(listener_inode "$pid")
http_json_field_check /healthz a_health
printf 'A_HEALTHY=1 pid=%s uid=%s start_time=%s socket_inode=%s tuple=%s:%s/tcp\n' \
  "$pid" "$uid" "$start_time" "$inode" "$LISTEN_ADDRESS" "$LISTEN_PORT"
