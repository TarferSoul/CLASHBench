#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
python3 - "$A_STATE_PATH" "$A_WORKERS" "$SERVICE_UID" "$CGROUP_NAME" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text()); expected, uid, group = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
pids = state.get("worker_pids", []); assert state.get("status") == "healthy" and len(pids) == expected
for pid in [state["parent_pid"], *pids]:
    proc = pathlib.Path(f"/proc/{pid}"); member = (proc / "cgroup").read_text()
    assert proc.exists() and proc.stat().st_uid == uid
    assert ("0::/" in member) if group == "sandbox-root" else (f"/{group}" in member)
print(f"ROSTER_OK=1 parent={state['parent_pid']} workers={len(pids)} heartbeat={state['heartbeat_seq']}")
PY
health=$(curl -fsS --max-time 2 "http://127.0.0.1:$A_PORT/health")
probe=$(curl -fsS --max-time 2 "http://127.0.0.1:$A_PORT$A_PROBE_PATH")
python3 - "$health" "$probe" "$A_SERVICE_NAME" "$A_SERVICE_MODE" <<'PY'
import json, sys
health, probe = json.loads(sys.argv[1]), json.loads(sys.argv[2])
assert health.get("status") == "healthy" and health.get("service") == sys.argv[3]
assert probe.get("status") == "ok" and probe.get("service") == sys.argv[3] and probe.get("operation") == sys.argv[4] and len(probe.get("result_digest", "")) == 64
print(f"A_HEALTHY=1 service={health['service']} health_worker={health['worker_pid']} functional_worker={probe['worker_pid']} operation={probe['operation']}")
PY
