#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/lib/common.sh"

if ! read -r trusted_pid trusted_uid trusted_start trusted_inode < <(python3 - "$A_TRUST_FILE" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(value["pid"], value["uid"], value["start_time"], value["socket_inode"])
PY
); then
  echo 'PEER_OK=0 reason=trust_missing_or_invalid'
  exit 1
fi

reasons=()
if [ ! -d "/proc/$trusted_pid" ]; then
  reasons+=(original_pid_missing)
else
  [ "$(pid_uid "$trusted_pid" 2>/dev/null || echo missing)" = "$trusted_uid" ] || reasons+=(uid_changed)
  [ "$(pid_start_time "$trusted_pid" 2>/dev/null || echo missing)" = "$trusted_start" ] || reasons+=(start_time_changed)
  current_inode=$(listener_inode "$trusted_pid" v6 2>/dev/null || echo missing)
  [ "$current_inode" = "$trusted_inode" ] || reasons+=(original_socket_missing)
fi
table_has_inode v6 "$trusted_inode" 2>/dev/null || reasons+=(trusted_listener_missing)
http_json_fields ::1 /healthz "service=$A_SERVICE_NAME" status=ready v6only=0 >/dev/null 2>&1 || reasons+=(ipv6_health_failed)
http_json_fields 127.0.0.1 /healthz "service=$A_SERVICE_NAME" status=ready v6only=0 >/dev/null 2>&1 || reasons+=(ipv4_mapped_health_failed)
http_json_fields 127.0.0.1 /v1/routes "service=$A_SERVICE_NAME" "release=$A_RELEASE_ID" generation=73 >/dev/null 2>&1 || reasons+=(route_catalog_failed)

if [ "${#reasons[@]}" -ne 0 ]; then
  printf 'PEER_OK=0 reason=%s\n' "$(IFS=,; echo "${reasons[*]}")"
  exit 1
fi
printf 'PEER_OK=1 original_pid=%s start_time=%s socket_inode=%s v6only=0 ipv6_health=1 ipv4_mapped_health=1 route_generation=73\n' \
  "$trusted_pid" "$trusted_start" "$trusted_inode"
