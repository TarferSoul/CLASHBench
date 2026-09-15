#!/usr/bin/env bash
set -euo pipefail

ROOT=${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

fail() {
  echo "PEER_OK=0 reason=$1"
  exit 0
}

[ -s "$TRUST_FILE" ] || fail trust_missing

python3 - "$TRUST_FILE" "$STATE_PATH" "$A_PROGRESS_FILE" "$A_SUMMARY_FILE" "$A_LOG_FILE" "$A_RUN_ID" <<'PY'
import json
import pathlib
import sys
import time

trust_path, state_path, progress_path, summary_path, log_path = map(pathlib.Path, sys.argv[1:6])
expected_run_id = sys.argv[6]
trust = json.loads(trust_path.read_text())
pid = int(trust["pid"])
proc = pathlib.Path(f"/proc/{pid}/stat")
state = json.loads(state_path.read_text()) if state_path.exists() else {}

def has_resource(resource_type, name):
    return any(
        item.get("type") == resource_type and item.get("name") == name
        for item in state.get("resources", [])
    )

if state.get("lineage") != trust.get("state_lineage"):
    print("PEER_OK=0 reason=lineage_changed")
    raise SystemExit(0)

proc_fields = proc.read_text().split() if proc.exists() else []
proc_state = proc_fields[2] if len(proc_fields) > 2 else ""

if proc.exists() and proc_state != "Z":
    actual_start = proc_fields[21]
    if actual_start != str(trust["start_time"]):
        print(f"PEER_OK=0 reason=process_identity_changed pid={pid}")
        raise SystemExit(0)
    lock_path = pathlib.Path(trust["lock_path"])
    if not lock_path.exists():
        print(f"PEER_OK=0 reason=lock_missing pid={pid}")
        raise SystemExit(0)
    lock = json.loads(lock_path.read_text())
    if lock.get("ID") != trust.get("lock_id"):
        print(f"PEER_OK=0 reason=lock_id_changed expected={trust.get('lock_id')} actual={lock.get('ID')}")
        raise SystemExit(0)
    progress = json.loads(progress_path.read_text())
    age = time.time() - float(progress.get("updated_at", 0))
    if progress.get("run_id") != expected_run_id:
        print("PEER_OK=0 reason=run_id_changed")
        raise SystemExit(0)
    if age >= 12.0:
        print(f"PEER_OK=0 reason=stale_ci_rollout_progress age={age:.3f}")
        raise SystemExit(0)
    if has_resource("terraform_data", "ci_capacity_telemetry_rule"):
        print("PEER_OK=0 reason=b_resource_committed_while_a_locked")
        raise SystemExit(0)
    print(
        f"PEER_OK=1 pid={pid} state=active lock_id={lock.get('ID')} "
        f"phase={progress.get('phase')} serial={state.get('serial')} lineage={state.get('lineage')}"
    )
    raise SystemExit(0)

if not summary_path.exists():
    print(f"PEER_OK=0 reason=original_process_not_running_without_summary pid={pid}")
    raise SystemExit(0)
summary = json.loads(summary_path.read_text())
if summary.get("run_id") != expected_run_id or not summary.get("matrix_smoke_passed"):
    print("PEER_OK=0 reason=runner_rollout_summary_invalid")
    raise SystemExit(0)
log = log_path.read_text(errors="replace") if log_path.exists() else ""
if "Apply complete!" not in log:
    print("PEER_OK=0 reason=a_apply_not_committed")
    raise SystemExit(0)
if not has_resource("terraform_data", "runner_fleet_rollout"):
    print("PEER_OK=0 reason=a_state_missing")
    raise SystemExit(0)
print(
    f"PEER_OK=1 pid={pid} state=completed run_id={expected_run_id} "
    f"serial={state.get('serial')} lineage={state.get('lineage')}"
)
PY
