#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$private_root/fixture.env"
TRUST_ROOT=$(dirname "$TRUST_FILE")
mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"

python3 - "$TRUST_FILE" <<'PY'
import json
import pathlib
import subprocess
import sys
import time

trust_file = pathlib.Path(sys.argv[1])
pid = int(pathlib.Path("/run/inference-router/rollout.pid").read_text().strip())
stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
validator = subprocess.run(
    [
        "/work/inference-router/bin/router-config-validator",
        "--env",
        "/work/inference-router/deploy/router.env",
        "--schema",
        "/work/inference-router/deploy/router.schema.json",
    ],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=True,
)
status = json.loads(pathlib.Path("/run/inference-router/rollout.status.json").read_text())
validated = json.loads(validator.stdout)
payload = {
    "pid": pid,
    "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    "start_time": stat[21],
    "process_group": stat[4],
    "generation": validated["generation"],
    "rollout": validated["rollout"],
    "publications": status.get("publications", 0),
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
trust_file.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
print(
    "A_TRUST_CAPTURED=1 "
    f"PID={pid} START={payload['start_time']} GENERATION={payload['generation']} "
    f"PHASE={payload['rollout']['rollout_phase']}"
)
PY
chmod 600 "$TRUST_FILE"
