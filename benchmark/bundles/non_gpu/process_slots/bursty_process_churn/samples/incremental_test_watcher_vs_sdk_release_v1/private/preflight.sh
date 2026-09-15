#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/fixture.env"
for command in python3 unshare mount runuser curl; do command -v "$command" >/dev/null; done
[[ -x $A_PROGRAM && -x $B_PROGRAM && -r $B_INPUT && -S $ADMISSION_SOCKET ]]
[[ -s $CONTROLLER_READY && -s $CGROUP_METRICS_PATH ]]
python3 - "$CONTROLLER_READY" "$PID_LIMIT" <<'PY'
import json, sys
value = json.loads(open(sys.argv[1]).read())
assert value.get("controller") == "pids" and int(value.get("pids_max")) == int(sys.argv[2])
PY
python3 -m json.tool "$(dirname "$0")/fixture.json" >/dev/null
python3 -m json.tool "$B_INPUT" >/dev/null
echo "PREFLIGHT_OK=1 watcher=incremental-test-watcher cgroup=$CGROUP_NAME pids_max=$PID_LIMIT"
