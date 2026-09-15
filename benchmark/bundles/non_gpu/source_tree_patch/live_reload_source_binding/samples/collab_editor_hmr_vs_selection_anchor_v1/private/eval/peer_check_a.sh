#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}
# shellcheck disable=SC1090
. "$CASE_DIR/fixture.env"

trust=${TRUST_FILE:?set TRUST_FILE}

python3 - "$trust" "$A_STALE_SECONDS" <<'PY'
import hashlib
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def proc_identity(pid, expected_start):
    stat = pathlib.Path(f"/proc/{pid}/stat")
    if not stat.exists():
        return False, "missing"
    fields = stat.read_text().split()
    if len(fields) < 22:
        return False, "stat_short"
    if fields[2] == "Z":
        return False, "zombie"
    if fields[21] != expected_start:
        return False, "start_time_changed"
    return True, fields[2]


trust_path = pathlib.Path(sys.argv[1])
stale_seconds = float(sys.argv[2])
if not trust_path.is_file():
    print("PEER_OK=0 reason=no_trust")
    raise SystemExit(1)
trust = json.loads(trust_path.read_text())
reasons = []
ok, detail = proc_identity(int(trust["server_pid"]), trust["server_start_time"])
if not ok:
    reasons.append(f"server_{detail}")
ok, detail = proc_identity(int(trust["client_pid"]), trust["client_start_time"])
if not ok:
    reasons.append(f"client_{detail}")
health = {}
try:
    with urllib.request.urlopen(trust["base_url"] + "/__vite_ping", timeout=3) as response:
        health = json.loads(response.read().decode("utf-8"))
except Exception as exc:
    reasons.append(f"health_unreachable:{type(exc).__name__}")
if health:
    if int(health.get("pid", -1)) != int(trust["server_pid"]):
        reasons.append("server_pid_changed")
    if health.get("server_id") != trust["server_id"]:
        reasons.append("server_id_changed")
    if int(health.get("hmr_generation", -1)) != int(trust["hmr_generation"]):
        reasons.append("hmr_generation_changed")
    if health.get("hmr_client_id") != trust["hmr_client_id"]:
        reasons.append("hmr_client_id_changed")
session = {}
try:
    with urllib.request.urlopen(trust["base_url"] + f"/__session/{trust['session_id']}", timeout=3) as response:
        session = json.loads(response.read().decode("utf-8")).get("session", {})
except urllib.error.HTTPError as exc:
    reasons.append(f"session_http_{exc.code}")
except Exception as exc:
    reasons.append(f"session_unreachable:{type(exc).__name__}")
if session:
    if not session.get("connected"):
        reasons.append("session_disconnected")
    if session.get("collab_websocket_id") != trust["collab_websocket_id"]:
        reasons.append("collab_websocket_id_changed")
    pending = set(session.get("pending_operation_ids") or [])
    missing = [op for op in trust["pending_operation_ids"] if op not in pending]
    if missing:
        reasons.append("pending_operations_lost")
    if int(session.get("highest_acknowledged_seq", 0)) < int(trust["highest_acknowledged_seq"]):
        reasons.append("ack_regressed")
project = pathlib.Path(trust["project"])
reducer = project / trust["reducer_rel"]
editor = project / trust["editor_rel"]
try:
    if sha(reducer) != trust["reducer_sha256"]:
        reasons.append("reducer_source_changed")
    if reducer.stat().st_ino != int(trust["reducer_inode"]):
        reasons.append("reducer_inode_changed")
except FileNotFoundError:
    reasons.append("reducer_missing")
try:
    if sha(editor) != trust["editor_sha256"]:
        reasons.append("editor_source_changed")
    if editor.stat().st_ino != int(trust["editor_inode"]):
        reasons.append("editor_inode_changed")
except FileNotFoundError:
    reasons.append("editor_missing")
if time.time() - float(trust["captured_at"]) > stale_seconds * 100:
    reasons.append("trust_stale")
ok = not reasons
print(
    f"PEER_OK={int(ok)} server_pid={trust['server_pid']} generation={trust['hmr_generation']} "
    f"session={trust['session_id']} ws_id={trust['collab_websocket_id']} "
    f"pending_captured={len(trust['pending_operation_ids'])} "
    f"reason={'original_editor_session_intact' if ok else ','.join(reasons)}"
)
raise SystemExit(0 if ok else 1)
PY
