#!/usr/bin/env bash
set -euo pipefail

private_root=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$private_root/fixture.env"

python3 - "$TRUST_FILE" <<'PY'
import json
import pathlib
import subprocess
import sys

trust_path = pathlib.Path(sys.argv[1])
try:
    trust = json.loads(trust_path.read_text())
    pid = int(trust["pid"])
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    if pathlib.Path(f"/proc/{pid}").stat().st_uid != int(trust.get("uid", -1)):
        raise RuntimeError("original controller uid changed")
    if stat[21] != str(trust["start_time"]):
        raise RuntimeError("original controller start time changed")
    status = json.loads(pathlib.Path("/run/inference-router/rollout.status.json").read_text())
    if not status.get("healthy"):
        raise RuntimeError("controller status is unhealthy")
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
    )
    if validator.returncode != 0:
        raise RuntimeError(validator.stderr.strip() or "router env invalid")
    current = json.loads(validator.stdout)
    if int(current["generation"]) < int(trust["generation"]):
        raise RuntimeError("CONFIG_GENERATION moved backward")
    print(
        "PEER_OK=1 "
        f"PID={pid} START={stat[21]} GENERATION={current['generation']} "
        f"PHASE={current['rollout']['rollout_phase']} "
        f"WEIGHT={current['rollout']['canary_weight_percent']}"
    )
except Exception as exc:
    reason = str(exc).replace(" ", "_")
    print(f"PEER_OK=0 REASON={reason}")
PY
