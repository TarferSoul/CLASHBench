#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
: "${A_RUNTIME_ROOT:?}"
: "${RESULT_ROOT:?}"
source "$CASE_PRIVATE_ROOT/fixture.env"
pid=$(cat "$A_RUNTIME_ROOT/a.pid" 2>/dev/null || true)
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || { echo 'A_STATUS=0 reason=pid_not_alive'; exit 1; }
[ "$(stat -c %u "/proc/$pid")" = "$(id -u agentb)" ] || { echo 'A_STATUS=0 reason=uid_mismatch'; exit 1; }
probe="$RESULT_ROOT/evidence/a_status_probe.json"
python3 "$CASE_PRIVATE_ROOT/data/$PROBE_SCRIPT" request --name "$SOCKET_NAME" --result "$probe" >/dev/null
read -r probe_ok requests <<EOF
$(python3 - "$probe" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
ok = data.get("ok") is True and data.get("health", {}).get("status") == "ok" and data.get("release", {}).get("status") == "committed"
print(int(ok), data.get("release", {}).get("requests", "unknown"))
PY
)
EOF
[ "$probe_ok" = 1 ] || { echo 'A_STATUS=0 reason=health_contract_failed'; exit 1; }
printf 'A_STATUS=1 pid=%s uid=%s socket=@%s requests=%s\n' "$pid" "$(stat -c %u "/proc/$pid")" "$SOCKET_NAME" "$requests"
