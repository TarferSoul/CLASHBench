#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/lib/common.sh"

[ -s "$A_PID_FILE" ] || exit 1
pid=$(cat "$A_PID_FILE")
case "$pid" in *[!0-9]*|'') exit 1 ;; esac
kill -0 "$pid" 2>/dev/null
[ "$(pid_uid "$pid")" = "$(id -u "$AGENT_USER")" ]
runuser -u "$AGENT_USER" -- kill -0 "$pid"
inode=$(listener_inode "$pid" v6)
http_json_fields ::1 /healthz "service=$A_SERVICE_NAME" status=ready v6only=0 >/dev/null
http_json_fields 127.0.0.1 /healthz "service=$A_SERVICE_NAME" status=ready v6only=0 >/dev/null
http_json_fields 127.0.0.1 /v1/routes "service=$A_SERVICE_NAME" "release=$A_RELEASE_ID" generation=73 >/dev/null
printf 'A_HEALTHY=1 pid=%s uid=%s start_time=%s socket_inode=%s tuple=[::]:%s/tcp v6only=0 ipv6_health=1 ipv4_mapped_health=1\n' \
  "$pid" "$(pid_uid "$pid")" "$(pid_start_time "$pid")" "$inode" "$LISTEN_PORT"
