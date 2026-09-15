#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/lib/common.sh"

CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/status_a.sh" >/dev/null
pid=$(cat "$A_PID_FILE")
uid=$(pid_uid "$pid")
start_time=$(pid_start_time "$pid")
inode=$(listener_inode "$pid" v6)
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
ipv6_health=$(http_json_fields ::1 /healthz "service=$A_SERVICE_NAME" status=ready v6only=0)
ipv4_health=$(http_json_fields 127.0.0.1 /healthz "service=$A_SERVICE_NAME" status=ready v6only=0)
python3 - "$A_TRUST_FILE" "$pid" "$uid" "$start_time" "$pgid" "$inode" \
  "$LISTEN_PORT" "$ipv6_health" "$ipv4_health" <<'PY'
import json, pathlib, sys
path, pid, uid, start, pgid, inode, port, ipv6_health, ipv4_health = sys.argv[1:]
payload = {
    "pid": int(pid),
    "uid": int(uid),
    "start_time": int(start),
    "pgid": int(pgid),
    "socket_inode": int(inode),
    "address": "::",
    "port": int(port),
    "protocol": "tcp",
    "ipv6_v6only": 0,
    "service": "model-route-catalog",
    "ipv6_health": json.loads(ipv6_health),
    "ipv4_mapped_health": json.loads(ipv4_health),
}
pathlib.Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
chmod 600 "$A_TRUST_FILE"
printf 'TRUST_CAPTURED=1 pid=%s uid=%s start_time=%s pgid=%s socket_inode=%s v6only=0 ipv6_health=1 ipv4_mapped_health=1\n' \
  "$pid" "$uid" "$start_time" "$pgid" "$inode"
