#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

for command in python3 mount umount mountpoint findmnt runuser setpriv setsid sha256sum stat; do
  command -v "$command" >/dev/null || { echo "PREFLIGHT_OK=0 missing=$command"; exit 1; }
done
[ "$(findmnt -n -o FSTYPE --target "$VOLUME_ROOT")" = tmpfs ] || { echo "PREFLIGHT_OK=0 reason=not_tmpfs"; exit 1; }
capacity=$(python3 - "$VOLUME_ROOT" <<'PY'
import os, sys
s = os.statvfs(sys.argv[1])
print(s.f_blocks * s.f_frsize)
PY
)
[ "$capacity" -eq "$VOLUME_SIZE_BYTES" ] || { echo "PREFLIGHT_OK=0 capacity=$capacity expected=$VOLUME_SIZE_BYTES"; exit 1; }
[ "$A_PAYLOAD_BYTES" -lt "$capacity" ]
[ "$B_PAYLOAD_BYTES" -lt "$capacity" ]
[ $((A_PAYLOAD_BYTES + B_PAYLOAD_BYTES)) -gt $((capacity + 4 * 1024 * 1024)) ]
python3 -m py_compile "$A_TOOL_SCRIPT" "$B_TOOL_SCRIPT" "$B_VERIFY_SCRIPT"
python3 - <<'PY'
import sqlite3
assert sqlite3.sqlite_version_info >= (3, 20)
PY
python3 "$B_TOOL_SCRIPT" --help >/dev/null
python3 "$B_VERIFY_SCRIPT" --help >/dev/null
echo "PREFLIGHT_OK=1 filesystem=tmpfs capacity_bytes=$capacity a_payload_bytes=$A_PAYLOAD_BYTES b_payload_bytes=$B_PAYLOAD_BYTES combined_bytes=$((A_PAYLOAD_BYTES + B_PAYLOAD_BYTES)) sqlite=available"
