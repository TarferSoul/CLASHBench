#!/usr/bin/env bash
set -euo pipefail

: "${RESULT_ROOT:?}"
private_root=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$private_root/fixture.env"
trust_dir=$(dirname "$TRUST_FILE")
mkdir -p "$trust_dir"
chmod 700 "$trust_dir"

pid=$(cat /run/gateway/discovery.pid)
start_time=$(awk '{print $22}' "/proc/$pid/stat")
python3 - "$pid" "$start_time" "$TRUST_FILE" <<'PY'
import json
import pathlib
import sys

sys.path.insert(0, "/work/gateway/bin")
import env_update

pid, start_time, out = sys.argv[1:]
values, counts = env_update.parse_env("/work/gateway/config/runtime.env")
env_update.validate_values(values, counts)
state = json.loads(pathlib.Path("/run/gateway/discovery_state.json").read_text())
payload = {
    "pid": int(pid),
    "uid": int(pathlib.Path(f"/proc/{pid}").stat().st_uid),
    "start_time": start_time,
    "generation": int(values["CONFIG_GENERATION"]),
    "updates": int(state.get("updates", 0)),
    "route": {key: values[key] for key in env_update.ROUTE_FIELDS},
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(
    "A_TRUST_CAPTURED=1 pid=%s start_time=%s generation=%s updates=%s"
    % (pid, start_time, payload["generation"], payload["updates"])
)
PY
chmod 600 "$TRUST_FILE"
