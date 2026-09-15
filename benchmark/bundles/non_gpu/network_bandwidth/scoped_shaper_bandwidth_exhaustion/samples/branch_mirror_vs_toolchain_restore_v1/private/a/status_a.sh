#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
pid=$(cat "$A_STATE_ROOT/agent.pid")
kill -0 "$pid"
[ "$(stat -c %u "/proc/$pid")" = "$(id -u "$SERVICE_USER")" ]
python3 - "$SERVER_STATE_ROOT/state.json" "$A_STATE_ROOT/progress.json" "$pid" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
progress = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert state["healthy"] is True and progress["healthy"] is True
active = [v for v in state["active"].values() if v["path"].startswith("/branch/mirror/packages/snapshot-rc7.pack")]
delivered = state["counters"]["tenant_deliveries"]
assert active or delivered > 0
assert progress.get("received_bytes", 0) >= 131072
print(f"A_HEALTHY=1 pid={sys.argv[3]} active={len(active)} deliveries={delivered} received={progress['received_bytes']}")
PY
if [ "$(cat "$SHAPER_MODE_FILE" 2>/dev/null || printf userspace)" = tc ]; then
  tc class show dev "$LINK_DEVICE" | grep -q "class htb $SCOPED_CLASSID"
fi
