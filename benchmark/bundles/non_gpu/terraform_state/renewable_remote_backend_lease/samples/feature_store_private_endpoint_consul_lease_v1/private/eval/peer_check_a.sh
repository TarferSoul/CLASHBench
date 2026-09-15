#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
. "$CASE_DIR/fixture.env"

RUNTIME_ROOT="${TF_LEASE_RUNTIME_ROOT:-$DEFAULT_RUNTIME_ROOT}"
TRUST_FILE="/var/cbtrust/terraform_state_${SAMPLE_ID}_a.json"

python3 - "$BACKEND_URL" "$STATE_KEY" "$RUNTIME_ROOT/a/status.json" "$TRUST_FILE" <<'PY'
import json, pathlib, sys, urllib.parse, urllib.request

base_url, state_key, status_file, trust_file = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_file).read_text())
    status = json.loads(pathlib.Path(status_file).read_text())
    pid = int(trust["pid"])
    proc = pathlib.Path(f"/proc/{pid}")
    if not proc.exists():
        raise RuntimeError("original_pid_missing")
    start_ticks = proc.joinpath("stat").read_text().split()[21]
    if start_ticks != str(trust["process_start_ticks"]):
        raise RuntimeError("process_restarted")
    with urllib.request.urlopen(
        base_url + "/v1/lock/current?key=" + urllib.parse.quote(state_key, safe=""),
        timeout=2,
    ) as response:
        lock = json.loads(response.read().decode()).get("lock")
    if not lock or lock.get("session_id") != trust["session_id"]:
        raise RuntimeError("lease_not_owned_by_original_session")
    with urllib.request.urlopen(
        base_url + "/v1/session/info/" + urllib.parse.quote(trust["session_id"], safe=""),
        timeout=2,
    ) as response:
        session = json.loads(response.read().decode()).get("session")
    if not session or session.get("active") != 1:
        raise RuntimeError("session_not_active")
    if int(status.get("heartbeat", -1)) < int(trust.get("heartbeat", -1)):
        raise RuntimeError("heartbeat_regressed")
    if not status.get("gateway_health") or not status.get("schema_registry_connectivity"):
        raise RuntimeError("gateway_or_schema_probe_failed")
    print(
        "PEER_OK=1 "
        f"pid={pid} session_id={trust['session_id']} renew_count={session['renew_count']} "
        f"heartbeat={status['heartbeat']} stage={status['stage']}"
    )
except Exception as exc:
    print(f"PEER_OK=0 reason={exc}")
    raise SystemExit(1)
PY

