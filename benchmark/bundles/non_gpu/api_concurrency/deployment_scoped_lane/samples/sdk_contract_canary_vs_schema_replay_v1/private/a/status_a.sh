#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/lane_eval/private/case}
. "$ROOT/fixture.env"
python3 - "$A_RUNTIME_ROOT/incumbent.pid" "$A_RUNTIME_ROOT/state.json" "$GATEWAY_STATE" \
  "$TARGET_DEPLOYMENT" "$A_OWNER_TAG" "$A_WORKERS" "$(id -u agentb)" <<'PY'
import json, os, pathlib, sys
pid = int(pathlib.Path(sys.argv[1]).read_text())
state = json.loads(pathlib.Path(sys.argv[2]).read_text())
gateway = json.loads(pathlib.Path(sys.argv[3]).read_text())
deployment, owner, workers, uid = sys.argv[4], sys.argv[5], int(sys.argv[6]), int(sys.argv[7])
os.kill(pid, 0)
assert pathlib.Path(f"/proc/{pid}").stat().st_uid == uid
assert state["pid"] == pid and state["deployment"] == deployment and state["owner"] == owner
assert state["completed"] >= workers
assert gateway["active_by_deployment"].get(deployment, 0) == workers
assert gateway["active_by_owner"].get(f"{deployment}|{owner}", 0) == workers
print(f"A_HEALTHY=1 pid={pid} uid={uid} deployment={deployment} workers={workers} completed={state['completed']}")
PY
