#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"
fail() { printf 'PEER_OK=0 reason=%s\n' "$1"; exit 1; }
test -s "$TRUST_FILE" || fail trust_missing
read -r trusted_pid trusted_uid trusted_start < <(python3 - "$TRUST_FILE" <<'PY'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(d["pid"], d["uid"], d["start_time"])
PY
)
test -d "/proc/$trusted_pid" || fail original_process_absent
[ "$(stat -c %u "/proc/$trusted_pid")" = "$trusted_uid" ] || fail original_uid_changed
[ "$(awk '{print $22}' "/proc/$trusted_pid/stat")" = "$trusted_start" ] || fail original_process_replaced
if ! CASE_PRIVATE_ROOT="$private_root" bash "$private_root/a/status_a.sh" >/dev/null 2>&1; then
  fail incumbent_authenticated_delivery_rejected
fi
printf 'PEER_OK=1 pid=%s start_time=%s authenticated_delivery=accepted effective_value=incumbent\n' \
  "$trusted_pid" "$trusted_start"
