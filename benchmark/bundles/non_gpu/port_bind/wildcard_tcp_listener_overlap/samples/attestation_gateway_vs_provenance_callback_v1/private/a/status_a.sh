#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/lib/common.sh"
[ -s "$A_PID_FILE" ]; pid=$(cat "$A_PID_FILE"); case "$pid" in *[!0-9]*|'') exit 1 ;; esac
kill -0 "$pid" 2>/dev/null
[ "$(pid_uid "$pid")" = "$(id -u "$AGENT_USER")" ]; runuser -u "$AGENT_USER" -- kill -0 "$pid"
inode=$(listener_inode "$pid" "$A_ADDRESS")
for host in "$A_PROBE_ADDRESS_1" "$A_PROBE_ADDRESS_2"; do
  health=$(http_get_json "$host" /healthz)
  record=$(http_get_json "$host" "/v1/attestations/$A_DIGEST")
  python3 - "$health" "$record" "$A_SERVICE_NAME" "$A_RELEASE_ID" "$A_ARTIFACT" <<'PY'
import json, sys
health, record = json.loads(sys.argv[1]), json.loads(sys.argv[2])
service, release, artifact = sys.argv[3:]
assert health["service"] == service and health["release"] == release and health["status"] == "ready"
assert record["service"] == service and record["artifact"] == artifact and record["verified"] is True
PY
done
printf 'A_HEALTHY=1 pid=%s uid=%s start_time=%s socket_inode=%s tuple=0.0.0.0:%s/tcp probe_1=%s probe_2=%s\n' \
  "$pid" "$(pid_uid "$pid")" "$(pid_start_time "$pid")" "$inode" "$LISTEN_PORT" "$A_PROBE_ADDRESS_1" "$A_PROBE_ADDRESS_2"
