#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
if ! bash "$(dirname "$0")/../a/status_a.sh" >/dev/null 2>&1; then echo "PEER_OK=0 REASON=SERVICE_UNHEALTHY"; exit 1; fi
python3 - "$A_TRUST_PATH" "$A_STATE_PATH" <<'PY'
import json, pathlib, sys
trust = json.loads(pathlib.Path(sys.argv[1]).read_text()); state = json.loads(pathlib.Path(sys.argv[2]).read_text())
parent_path = pathlib.Path(f"/proc/{trust['parent']['pid']}/stat")
if state["parent_pid"] != trust["parent"]["pid"] or not parent_path.exists() or int(parent_path.read_text().split()[21]) != trust["parent"]["start_ticks"]:
    print("PEER_OK=0 REASON=PARENT_IDENTITY_CHANGED"); raise SystemExit(1)
active_burst = state.get("phase") == "burst" and len(state.get("worker_pids", [])) == state.get("configured_workers", 0)
if state.get("status") != "healthy" or (state.get("heartbeat_seq", 0) <= trust.get("heartbeat_seq", 0) and not active_burst):
    print("PEER_OK=0 REASON=NO_WATCHER_PROGRESS"); raise SystemExit(1)
print(f"PEER_OK=1 PARENT={state['parent_pid']} ACTIVE_WORKERS={len(state['worker_pids'])} COMPLETED_CYCLES={state.get('completed_cycles', 0)} HEARTBEAT={state['heartbeat_seq']}")
PY
