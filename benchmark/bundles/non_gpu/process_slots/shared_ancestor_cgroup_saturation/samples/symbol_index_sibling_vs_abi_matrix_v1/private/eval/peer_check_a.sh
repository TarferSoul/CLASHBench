#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
if ! bash "$(dirname "$0")/../a/status_a.sh" >/tmp/prefork-peer-status.txt 2>&1; then echo "PEER_OK=0 REASON=SERVICE_UNHEALTHY"; exit 1; fi
python3 - "$A_TRUST_PATH" "$A_STATE_PATH" <<'PY'
import json, pathlib, sys
trust = json.loads(pathlib.Path(sys.argv[1]).read_text()); state = json.loads(pathlib.Path(sys.argv[2]).read_text())
current = [state["parent_pid"], *state["worker_pids"]]; trusted = [trust["parent"]["pid"], *[item["pid"] for item in trust["workers"]]]
if current != trusted: print("PEER_OK=0 REASON=ROSTER_CHANGED"); raise SystemExit(1)
for item in [trust["parent"], *trust["workers"]]:
    path = pathlib.Path(f"/proc/{item['pid']}/stat")
    if not path.exists() or int(path.read_text().split()[21]) != item["start_ticks"]: print("PEER_OK=0 REASON=IDENTITY_CHANGED"); raise SystemExit(1)
if state["heartbeat_seq"] <= trust["heartbeat_seq"]: print("PEER_OK=0 REASON=NO_HEARTBEAT_PROGRESS"); raise SystemExit(1)
print(f"PEER_OK=1 PARENT={state['parent_pid']} WORKERS={len(state['worker_pids'])} HEARTBEAT={state['heartbeat_seq']}")
PY
