#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/lib/common.sh"
if ! read -r trusted_pid trusted_uid trusted_start trusted_inode < <(python3 - "$A_TRUST_FILE" <<'PY'
import json, pathlib, sys
x = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(x["pid"], x["uid"], x["start_time"], x["socket_inode"])
PY
); then echo 'PEER_OK=0 reason=trust_missing_or_invalid'; exit 1; fi
reasons=()
if [ ! -d "/proc/$trusted_pid" ]; then reasons+=(original_pid_missing); else
  [ "$(pid_uid "$trusted_pid" 2>/dev/null || echo missing)" = "$trusted_uid" ] || reasons+=(uid_changed)
  [ "$(pid_start_time "$trusted_pid" 2>/dev/null || echo missing)" = "$trusted_start" ] || reasons+=(start_time_changed)
  [ "$(listener_inode "$trusted_pid" "$A_ADDRESS" 2>/dev/null || echo missing)" = "$trusted_inode" ] || reasons+=(original_socket_missing)
fi
table_has_inode "$trusted_inode" 2>/dev/null || reasons+=(trusted_listener_missing)
for host in "$A_PROBE_ADDRESS_1" "$A_PROBE_ADDRESS_2"; do
  health=$(http_get_json "$host" /healthz 2>/dev/null || echo '{}')
  record=$(http_get_json "$host" "/v1/attestations/$A_DIGEST" 2>/dev/null || echo '{}')
  python3 - "$health" "$record" "$A_SERVICE_NAME" "$A_RELEASE_ID" "$A_ARTIFACT" <<'PY' >/dev/null 2>&1 || reasons+=(protocol_health_failed)
import json, sys
h, r = json.loads(sys.argv[1]), json.loads(sys.argv[2])
assert h.get("service") == sys.argv[3] and h.get("release") == sys.argv[4] and h.get("status") == "ready"
assert r.get("service") == sys.argv[3] and r.get("artifact") == sys.argv[5] and r.get("verified") is True
PY
done
if [ "${#reasons[@]}" -ne 0 ]; then printf 'PEER_OK=0 reason=%s\n' "$(IFS=,; echo "${reasons[*]}")"; exit 1; fi
printf 'PEER_OK=1 original_pid=%s start_time=%s socket_inode=%s wildcard=0.0.0.0 multi_address_health=1\n' \
  "$trusted_pid" "$trusted_start" "$trusted_inode"
