#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-$(cd "$(dirname "$0")/.." && pwd)}
# shellcheck disable=SC1090
. "$CASE_DIR/fixture.env"

state=${A_STATE_ROOT:?set A_STATE_ROOT}
dev_port=${DEV_PORT_OVERRIDE:-$DEV_PORT}
require_session=${REQUIRE_EDITOR_SESSION:-1}

python3 - "$state" "$HOST" "$dev_port" "$A_SESSION_ID" "$A_MIN_PENDING" "$A_MIN_ACK" "$require_session" <<'PY'
import json
import pathlib
import sys
import urllib.error
import urllib.request


def proc_ok(pid, expected_start=None):
    stat = pathlib.Path(f"/proc/{pid}/stat")
    if not stat.exists():
        return False, "missing"
    fields = stat.read_text().split()
    if len(fields) < 22:
        return False, "stat_short"
    if fields[2] == "Z":
        return False, "zombie"
    if expected_start and fields[21] != expected_start:
        return False, "start_time_changed"
    return True, fields[21]


state = pathlib.Path(sys.argv[1])
host, port, session_id = sys.argv[2], sys.argv[3], sys.argv[4]
min_pending, min_ack = int(sys.argv[5]), int(sys.argv[6])
require_session = sys.argv[7] == "1"
reasons = []
server_pid_path = state / "server.pid"
if not server_pid_path.is_file():
    reasons.append("server_pid_missing")
    server_pid = -1
else:
    server_pid = int(server_pid_path.read_text().strip())
    expected = (state / "server.start").read_text().strip() if (state / "server.start").is_file() else None
    ok, detail = proc_ok(server_pid, expected)
    if not ok:
        reasons.append(f"server_{detail}")
try:
    with urllib.request.urlopen(f"http://{host}:{port}/__vite_ping", timeout=2) as response:
        health = json.loads(response.read().decode("utf-8"))
except Exception as exc:
    health = {}
    reasons.append(f"health_unreachable:{type(exc).__name__}")

session = {}
if require_session:
    client_pid_path = state / "client.pid"
    if not client_pid_path.is_file():
        reasons.append("client_pid_missing")
    else:
        client_pid = int(client_pid_path.read_text().strip())
        expected = (state / "client.start").read_text().strip() if (state / "client.start").is_file() else None
        ok, detail = proc_ok(client_pid, expected)
        if not ok:
            reasons.append(f"client_{detail}")
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/__session/{session_id}", timeout=2) as response:
            session_payload = json.loads(response.read().decode("utf-8"))
        session = session_payload.get("session", {})
    except urllib.error.HTTPError as exc:
        reasons.append(f"session_http_{exc.code}")
    except Exception as exc:
        reasons.append(f"session_unreachable:{type(exc).__name__}")
    if session:
        pending = session.get("pending_operation_ids") or []
        ack = int(session.get("highest_acknowledged_seq", 0))
        if not session.get("connected"):
            reasons.append("session_disconnected")
        if len(pending) < min_pending:
            reasons.append(f"pending_lt_{min_pending}")
        if ack < min_ack:
            reasons.append(f"ack_lt_{min_ack}")
else:
    pending = []
    ack = 0

ok = not reasons
generation = health.get("hmr_generation", "missing")
print(
    f"A_HEALTHY={int(ok)} server_pid={server_pid} generation={generation} "
    f"session={session_id} pending={len(session.get('pending_operation_ids') or []) if session else 0} "
    f"ack={session.get('highest_acknowledged_seq', 0) if session else 0} "
    f"reason={'ready' if ok else ','.join(reasons)}"
)
raise SystemExit(0 if ok else 1)
PY
