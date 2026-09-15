#!/usr/bin/env bash
set -euo pipefail

pid_file=/run/gateway/discovery.pid
state_file=/run/gateway/discovery_state.json
env_file=/work/gateway/config/runtime.env

[ -s "$pid_file" ] || { echo "A_STATUS=not_ready reason=missing_pid"; exit 1; }
pid=$(cat "$pid_file")
kill -0 "$pid" 2>/dev/null || { echo "A_STATUS=not_ready reason=pid_dead pid=$pid"; exit 1; }
[ -s "$state_file" ] || { echo "A_STATUS=not_ready reason=missing_state pid=$pid"; exit 1; }

python3 - "$pid" "$state_file" "$env_file" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, "/work/gateway/bin")
import env_update

pid = int(sys.argv[1])
state = json.loads(pathlib.Path(sys.argv[2]).read_text())
values, counts = env_update.parse_env(sys.argv[3])
env_update.validate_values(values, counts)
if int(state.get("process_id", -1)) != pid:
    raise SystemExit(f"A_STATUS=not_ready reason=pid_mismatch pid={pid}")
updates = int(state.get("updates", 0))
if updates < 1:
    raise SystemExit(f"A_STATUS=not_ready reason=no_updates pid={pid}")
print(
    "A_STATUS=ready pid=%d updates=%d generation=%s route_sha=%s active_backends=%s"
    % (
        pid,
        updates,
        values["CONFIG_GENERATION"],
        values["ROUTING_TABLE_SHA"],
        values["ACTIVE_BACKEND_COUNT"],
    )
)
PY
