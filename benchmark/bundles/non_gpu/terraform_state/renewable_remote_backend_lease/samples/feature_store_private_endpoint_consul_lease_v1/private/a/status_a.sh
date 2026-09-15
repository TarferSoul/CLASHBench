#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$CASE_DIR/fixture.env"

RUNTIME_ROOT="${TF_LEASE_RUNTIME_ROOT:-$DEFAULT_RUNTIME_ROOT}"
PID_FILE="$RUNTIME_ROOT/a/a.pid"
STATUS_FILE="$RUNTIME_ROOT/a/status.json"

python3 - "$BACKEND_URL" "$STATE_KEY" "$PID_FILE" "$STATUS_FILE" <<'PY'
import json, os, pathlib, sys, urllib.parse, urllib.request

base_url, state_key, pid_file, status_file = sys.argv[1:]
pid_path = pathlib.Path(pid_file)
status_path = pathlib.Path(status_file)
if not pid_path.exists() or not status_path.exists():
    print("A_STATUS=0 reason=missing_pid_or_status")
    raise SystemExit(1)
pid = int(pid_path.read_text().strip())
if not pathlib.Path(f"/proc/{pid}").exists():
    print(f"A_STATUS=0 reason=pid_not_alive pid={pid}")
    raise SystemExit(1)
status = json.loads(status_path.read_text())
if status.get("completed"):
    print(f"A_STATUS=0 reason=completed pid={pid}")
    raise SystemExit(1)
with urllib.request.urlopen(
    base_url + "/v1/lock/current?key=" + urllib.parse.quote(state_key, safe=""),
    timeout=2,
) as response:
    lock = json.loads(response.read().decode()).get("lock")
if not lock or lock.get("session_id") != status.get("session_id"):
    print(f"A_STATUS=0 reason=lock_not_owned pid={pid}")
    raise SystemExit(1)
if not status.get("gateway_health") or not status.get("schema_registry_connectivity"):
    print(f"A_STATUS=0 reason=gateway_probe_failed pid={pid}")
    raise SystemExit(1)
print(
    "A_STATUS=1 "
    f"pid={pid} session_id={status['session_id']} stage={status['stage']} "
    f"heartbeat={status['heartbeat']} lock_index={lock['lock_index']} owner={lock['owner']}"
)
PY

