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
inode=$(listener_inode "$pid")
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
mkdir -p "$(dirname "$TRUST_FILE")"
chmod 700 "$(dirname "$TRUST_FILE")"
python3 - "$TRUST_FILE" "$pid" "$uid" "$start_time" "$pgid" "$inode" "$LISTEN_ADDRESS" "$LISTEN_PORT" <<'PY'
import json, pathlib, sys
path, pid, uid, start, pgid, inode, address, port = sys.argv[1:]
payload = {
    "pid": int(pid),
    "uid": int(uid),
    "start_time": int(start),
    "pgid": int(pgid),
    "socket_inode": int(inode),
    "address": address,
    "port": int(port),
    "protocol": "tcp",
    "service": "ci-webhook-receiver",
    "workspace": "release-pipeline",
}
pathlib.Path(path).write_text(json.dumps(payload, indent=2) + "\n")
PY
chmod 600 "$TRUST_FILE"
printf 'TRUST_CAPTURED=1 pid=%s uid=%s start_time=%s pgid=%s socket_inode=%s\n' \
  "$pid" "$uid" "$start_time" "$pgid" "$inode"
