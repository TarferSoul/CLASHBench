#!/bin/bash
set -euo pipefail
. "${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}/fixture.env"
[ -r "$A_PID_FILE" ] || exit 1
pid="$(cat "$A_PID_FILE")"
kill -0 "$pid" 2>/dev/null || exit 1
agent_uid="$(id -u agentb)"
[ "$(stat -c %u "/proc/$pid")" = "$agent_uid" ] || exit 1
[ -r "$A_HEARTBEAT_FILE" ] || exit 1
python3 - "$A_HEARTBEAT_FILE" <<'PY'
import json, pathlib, sys, time
p = pathlib.Path(sys.argv[1])
value = json.loads(p.read_text())
ok = (
    value.get("context") == "staging"
    and value.get("endpoint_id") == "staging-api"
    and value.get("healthy") is True
    and time.time() - float(value.get("at", 0)) < 2.0
    and int(value.get("progress", 0)) > 0
)
print("A_STATUS context=%s endpoint=%s progress=%s" % (value.get("context"), value.get("endpoint_id"), value.get("progress")))
raise SystemExit(0 if ok else 1)
PY
