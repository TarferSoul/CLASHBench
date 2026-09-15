#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
pid=$(cat "$A_STATE_ROOT/agent.pid")
uid=$(stat -c %u "/proc/$pid")
starttime=$(awk '{print $22}' "/proc/$pid/stat")
pgid=$(awk '{print $5}' "/proc/$pid/stat")
if [ "$(cat "$SHAPER_MODE_FILE" 2>/dev/null || printf userspace)" = tc ]; then
  fingerprint=$({ tc qdisc show dev "$LINK_DEVICE"; tc class show dev "$LINK_DEVICE"; tc filter show dev "$LINK_DEVICE" parent 1:; } | sha256sum | awk '{print $1}')
else
  fingerprint=$(printf 'userspace scope_rate_bps=%s parent_rate_bps=125000000\n' "$SCOPE_RATE_BPS" | sha256sum | awk '{print $1}')
fi
python3 - "$A_TRUST_PATH" "$pid" "$uid" "$starttime" "$pgid" "$fingerprint" "$SERVER_STATE_ROOT/state.json" <<'PY'
import json, pathlib, sys, time
out, pid, uid, start, pgid, fingerprint, state_path = sys.argv[1:]
state = json.loads(pathlib.Path(state_path).read_text())
pathlib.Path(out).write_text(json.dumps({
    "pid": int(pid), "uid": int(uid), "starttime": int(start), "pgid": int(pgid),
    "class_fingerprint": fingerprint, "captured_at": time.time(),
    "tenant_bytes": state["counters"]["tenant_bytes"],
    "tenant_deliveries": state["counters"]["tenant_deliveries"]
}, sort_keys=True, indent=2) + "\n")
PY
chmod 600 "$A_TRUST_PATH"
tc -s -j class show dev "$LINK_DEVICE" >"${A_TRUST_PATH%.json}.classes.json"
echo "TRUST_CAPTURED=1 pid=$pid uid=$uid class=$SCOPED_CLASSID"
