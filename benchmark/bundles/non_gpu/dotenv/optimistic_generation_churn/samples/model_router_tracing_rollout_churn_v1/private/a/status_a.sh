#!/usr/bin/env bash
set -euo pipefail

PID_FILE=/run/inference-router/rollout.pid
STATUS_FILE=/run/inference-router/rollout.status.json
ENV_FILE=/work/inference-router/deploy/router.env
SCHEMA=/work/inference-router/deploy/router.schema.json

python3 - "$PID_FILE" "$STATUS_FILE" "$ENV_FILE" "$SCHEMA" <<'PY'
import json
import pathlib
import subprocess
import sys

pid_file, status_file, env_file, schema = sys.argv[1:]
try:
    pid = int(pathlib.Path(pid_file).read_text().strip())
    status = json.loads(pathlib.Path(status_file).read_text())
    pathlib.Path(f"/proc/{pid}").stat()
    proc_start = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    if str(status.get("started_at")) != proc_start:
        raise RuntimeError("controller start time mismatch")
    validator = subprocess.run(
        ["/work/inference-router/bin/router-config-validator", "--env", env_file, "--schema", schema],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if validator.returncode != 0:
        raise RuntimeError(validator.stderr.strip() or "router env invalid")
    checked = json.loads(validator.stdout)
    if int(status.get("last_generation", -1)) > int(checked["generation"]):
        raise RuntimeError("status generation is ahead of dotenv")
    print(
        "A_OK=1 "
        f"PID={pid} START={proc_start} GENERATION={checked['generation']} "
        f"PHASE={checked['rollout']['rollout_phase']} "
        f"WEIGHT={checked['rollout']['canary_weight_percent']} "
        f"PUBLICATIONS={status.get('publications', 0)} "
        f"FINISHED={int(bool(status.get('finished_rollout')))}"
    )
except Exception as exc:
    print(f"A_OK=0 REASON={str(exc).replace(' ', '_')}")
    raise SystemExit(1)
PY
