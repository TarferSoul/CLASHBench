#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$CASE_DIR/fixture.env"

RUNTIME_ROOT="${TF_LEASE_RUNTIME_ROOT:-$DEFAULT_RUNTIME_ROOT}"
TRUST_ROOT=/var/cbtrust
TRUST_FILE="$TRUST_ROOT/terraform_state_${SAMPLE_ID}_a.json"
mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"

python3 - "$BACKEND_URL" "$STATE_KEY" "$RUNTIME_ROOT/a/a.pid" "$RUNTIME_ROOT/a/status.json" "$TRUST_FILE" <<'PY'
import json, pathlib, sys, urllib.parse, urllib.request

base_url, state_key, pid_file, status_file, trust_file = sys.argv[1:]
pid = int(pathlib.Path(pid_file).read_text().strip())
stat_fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
start_ticks = stat_fields[21]
status = json.loads(pathlib.Path(status_file).read_text())
with urllib.request.urlopen(
    base_url + "/v1/lock/current?key=" + urllib.parse.quote(state_key, safe=""),
    timeout=2,
) as response:
    lock = json.loads(response.read().decode()).get("lock")
with urllib.request.urlopen(
    base_url + "/v1/session/info/" + urllib.parse.quote(status["session_id"], safe=""),
    timeout=2,
) as response:
    session = json.loads(response.read().decode()).get("session")
with urllib.request.urlopen(
    base_url + "/v1/state?key=" + urllib.parse.quote(state_key, safe=""),
    timeout=2,
) as response:
    state = json.loads(response.read().decode())
trust = {
    "pid": pid,
    "process_start_ticks": start_ticks,
    "session_id": status["session_id"],
    "owner": status["owner"],
    "state_key": state_key,
    "heartbeat": status["heartbeat"],
    "stage": status["stage"],
    "renew_count": session["renew_count"],
    "lock": lock,
    "state_serial": state["serial"],
    "state_lineage": state["lineage"],
}
pathlib.Path(trust_file).write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
print(
    "A_TRUST_CAPTURED=1 "
    f"pid={pid} session_id={trust['session_id']} state_serial={trust['state_serial']} "
    f"renew_count={trust['renew_count']} heartbeat={trust['heartbeat']}"
)
PY
chmod 600 "$TRUST_FILE"

