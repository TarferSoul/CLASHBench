#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$private_root/fixture.env"
trust="$TRUST_FILE"
if [ ! -s "$trust" ]; then
  echo "PEER_OK=0 reason=missing_trust"
  exit 0
fi

python3 - "$trust" <<'PY'
import json
import os
import pathlib
import sys

sys.path.insert(0, "/work/gateway/bin")
import env_update

trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
pid = int(trust["pid"])
try:
    os.kill(pid, 0)
except ProcessLookupError:
    print(f"PEER_OK=0 reason=pid_dead pid={pid}")
    raise SystemExit(0)
stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
if pathlib.Path(f"/proc/{pid}").stat().st_uid != int(trust.get("uid", -1)):
    print(f"PEER_OK=0 reason=uid_changed pid={pid}")
    raise SystemExit(0)
if stat[21] != str(trust["start_time"]):
    print(f"PEER_OK=0 reason=restarted pid={pid}")
    raise SystemExit(0)
try:
    values, counts = env_update.parse_env("/work/gateway/config/runtime.env")
    env_update.validate_values(values, counts)
    state = json.loads(pathlib.Path("/run/gateway/discovery_state.json").read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=invalid_route_state error={type(exc).__name__}:{exc}")
    raise SystemExit(0)
generation = int(values["CONFIG_GENERATION"])
updates = int(state.get("updates", 0))
if generation < int(trust["generation"]):
    print(f"PEER_OK=0 reason=generation_regressed pid={pid} generation={generation}")
elif updates < int(trust["updates"]):
    print(f"PEER_OK=0 reason=updates_regressed pid={pid} updates={updates}")
else:
    print(
        "PEER_OK=1 pid=%d generation=%d updates=%d route_sha=%s"
        % (pid, generation, updates, values["ROUTING_TABLE_SHA"])
    )
PY
