#!/usr/bin/env bash
set -euo pipefail

ROOT=${SMOKE_ROOT:?SMOKE_ROOT must point to the private fixture}
STATE_ROOT=${A_STATE_ROOT:-$ROOT}
STATE="$STATE_ROOT/a/state"
if [ ! -s "$STATE/pid" ] || [ ! -s "$STATE/service.json" ]; then
  echo 'A_HEALTHY=0 reason=state_missing'
  exit 1
fi
pid=$(cat "$STATE/pid")
if ! kill -0 "$pid" 2>/dev/null; then
  echo "A_HEALTHY=0 reason=pid_dead pid=$pid"
  exit 1
fi
python3 - "$STATE/service.json" <<'PY'
import json, pathlib, sys, urllib.request
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
if state.get("ready") != 1 or len(state.get("objects", [])) < 2:
    print("A_HEALTHY=0 reason=state_not_ready")
    raise SystemExit(1)
for item in state["objects"]:
    path = pathlib.Path("/dev/shm") / item["name"]
    if not path.exists() or path.stat().st_blocks * 512 != item.get("allocated_bytes"):
        print("A_HEALTHY=0 reason=object_allocation_missing")
        raise SystemExit(1)
try:
    with urllib.request.urlopen("http://127.0.0.1:%d/health" % state["port"], timeout=2) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
except Exception as exc:
    print("A_HEALTHY=0 reason=health_request_%s" % type(exc).__name__)
    raise SystemExit(1)
if payload.get("ready") != 1 or payload.get("object_count") != len(state["objects"]):
    print("A_HEALTHY=0 reason=health_payload_mismatch")
    raise SystemExit(1)
print("A_HEALTHY=1 pid=%s prefix=%s objects=%s allocated=%s checksum=%s workers=%s heartbeat=%s" %
      (state["pid"], state["objects"][0]["name"].rsplit("_", 1)[0], len(state["objects"]),
       sum(item["allocated_bytes"] for item in state["objects"]), state["aggregate_checksum"],
       len(state.get("worker_pids", [])), state.get("heartbeat", 0)))
PY
