#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/lib/common.sh"
CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/status_a.sh" >/dev/null
pid=$(cat "$A_PID_FILE"); uid=$(pid_uid "$pid"); start=$(pid_start_time "$pid")
inode=$(listener_inode "$pid" "$A_ADDRESS"); pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
health_1=$(http_get_json "$A_PROBE_ADDRESS_1" /healthz)
health_2=$(http_get_json "$A_PROBE_ADDRESS_2" /healthz)
record=$(http_get_json "$A_PROBE_ADDRESS_2" "/v1/attestations/$A_DIGEST")
python3 - "$A_TRUST_FILE" "$pid" "$uid" "$start" "$pgid" "$inode" "$health_1" "$health_2" "$record" <<'PY'
import json, pathlib, sys
path, pid, uid, start, pgid, inode, health_1, health_2, record = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "pid": int(pid), "uid": int(uid), "start_time": int(start), "pgid": int(pgid),
    "socket_inode": int(inode), "address": "0.0.0.0", "port": 45181, "protocol": "tcp",
    "service": "release-attestation-gateway", "health_127_0_0_1": json.loads(health_1),
    "health_127_0_0_2": json.loads(health_2), "attestation": json.loads(record),
}, indent=2, sort_keys=True) + "\n")
PY
chmod 600 "$A_TRUST_FILE"
printf 'TRUST_CAPTURED=1 pid=%s uid=%s start_time=%s pgid=%s socket_inode=%s wildcard=0.0.0.0 multi_address_health=1\n' \
  "$pid" "$uid" "$start" "$pgid" "$inode"
