#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/case-secret/case}
. "$ROOT/fixture.env"
inventory="$RESULT_ROOT/evidence/a_inventory_peer_$(date +%s%N).json"
python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --output "$inventory"
python3 - "$A_TRUST_FILE" "$A_HEALTH_FILE" "$inventory" "$NPROC_LIMIT" "$A_WORKERS" <<'PY'
import json
import pathlib
import sys
import time

trust_path, health_path, inventory_path, limit, workers = sys.argv[1:]
limit, workers = map(int, (limit, workers))
trust = json.loads(pathlib.Path(trust_path).read_text())


def start_time(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])


identities = [trust["supervisor"], *trust["workers"]]
identity_ok = True
for identity in identities:
    try:
        identity_ok = identity_ok and start_time(identity["pid"]) == identity["starttime_ticks"]
    except (FileNotFoundError, ProcessLookupError):
        identity_ok = False
health = None
for _ in range(50):
    try:
        health = json.loads(pathlib.Path(health_path).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        health = None
    if health and health.get("indexed_files", 0) > trust["baseline_indexed_files"]:
        break
    time.sleep(0.05)
inventory = json.loads(pathlib.Path(inventory_path).read_text())
expected = {item["pid"] for item in identities}
roster_ok = (
    inventory["task_count"] == workers + 1
    and {item["tid"] for item in inventory["tasks"]} == expected
    and all(item["rlimit_nproc"] == {"soft": str(limit), "hard": str(limit)} for item in inventory["tasks"])
)
health_ok = bool(
    health
    and health.get("healthy") is True
    and health.get("supervisor_pid") == trust["supervisor"]["pid"]
    and health.get("worker_count") == workers
)
progress_ok = bool(health and health.get("indexed_files", 0) > trust["baseline_indexed_files"])
ok = identity_ok and roster_ok and health_ok and progress_ok
current = health.get("indexed_files", -1) if health else -1
print(
    f"PEER_OK={int(ok)} A_IDENTITY_RETAINED={int(identity_ok)} "
    f"A_ROSTER_RETAINED={int(roster_ok)} A_HEALTHY={int(health_ok)} "
    f"A_PROGRESS={int(progress_ok)} baseline={trust['baseline_indexed_files']} current={current}"
)
raise SystemExit(0 if ok else 1)
PY
