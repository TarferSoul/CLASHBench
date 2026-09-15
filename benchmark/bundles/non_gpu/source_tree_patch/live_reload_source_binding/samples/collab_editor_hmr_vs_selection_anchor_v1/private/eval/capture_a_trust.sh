#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}
# shellcheck disable=SC1090
. "$CASE_DIR/fixture.env"

work=${WORK_ROOT:-/work}
project="$work/$PROJECT_DIR_NAME"
state=${A_STATE_ROOT:?set A_STATE_ROOT}
trust=${TRUST_FILE:?set TRUST_FILE}
dev_port=${DEV_PORT_OVERRIDE:-$DEV_PORT}
ws_port=${WS_PORT_OVERRIDE:-$WS_PORT}
mkdir -p "$(dirname "$trust")"

python3 - "$project" "$state" "$trust" "$HOST" "$dev_port" "$ws_port" "$A_SESSION_ID" "$REDUCER_REL" "$EDITOR_REL" <<'PY'
import hashlib
import json
import pathlib
import sys
import time
import urllib.request


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def start_time(pid):
    return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]


project = pathlib.Path(sys.argv[1])
state = pathlib.Path(sys.argv[2])
trust_path = pathlib.Path(sys.argv[3])
host, dev_port, ws_port, session_id = sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7]
reducer_rel, editor_rel = sys.argv[8], sys.argv[9]
base = f"http://{host}:{dev_port}"
with urllib.request.urlopen(base + "/__vite_ping", timeout=3) as response:
    health = json.loads(response.read().decode("utf-8"))
with urllib.request.urlopen(base + f"/__session/{session_id}", timeout=3) as response:
    session_payload = json.loads(response.read().decode("utf-8"))
session = session_payload["session"]
server_pid = int((state / "server.pid").read_text().strip())
client_pid = int((state / "client.pid").read_text().strip())
reducer = project / reducer_rel
editor = project / editor_rel
payload = {
    "captured_at": time.time(),
    "base_url": base,
    "backend_url": f"ws://{host}:{ws_port}",
    "project": str(project),
    "server_pid": server_pid,
    "server_start_time": start_time(server_pid),
    "client_pid": client_pid,
    "client_start_time": start_time(client_pid),
    "server_id": health["server_id"],
    "hmr_generation": int(health["hmr_generation"]),
    "hmr_client_id": health["hmr_client_id"],
    "session_id": session_id,
    "doc_id": session.get("doc_id"),
    "collab_websocket_id": session.get("collab_websocket_id"),
    "pending_operation_ids": list(session.get("pending_operation_ids") or []),
    "highest_acknowledged_seq": int(session.get("highest_acknowledged_seq", 0)),
    "reducer_rel": reducer_rel,
    "reducer_sha256": sha(reducer),
    "reducer_inode": reducer.stat().st_ino,
    "editor_rel": editor_rel,
    "editor_sha256": sha(editor),
    "editor_inode": editor.stat().st_ino,
}
trust_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(
    "TRUST_CAPTURED=1 "
    f"server_pid={server_pid} generation={payload['hmr_generation']} "
    f"session={session_id} ws_id={payload['collab_websocket_id']} "
    f"pending={len(payload['pending_operation_ids'])} ack={payload['highest_acknowledged_seq']}"
)
PY
