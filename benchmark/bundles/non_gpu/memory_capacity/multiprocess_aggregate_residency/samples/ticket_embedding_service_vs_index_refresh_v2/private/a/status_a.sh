#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

runuser -u "$SERVICE_USER" -- python3 - "$(cat "$A_RUNTIME_ROOT/service.pid")" "$A_STATE_ROOT" "$A_HOST" "$A_PORT" "$A_WORKER_COUNT" "$A_AGGREGATE_PSS_FLOOR_KIB" "$A_WORKER_PSS_FLOOR_KIB" "$A_WORKER_PSS_CEILING_KIB" "$A_CANARY_CHECKSUM" <<'PY'
import json
import os
import pathlib
import sys
import time
import urllib.request

pid_file, state_root, host, port, worker_count, aggregate_floor, worker_floor, worker_ceiling, expected_checksum = sys.argv[1:]
state_root = pathlib.Path(state_root)
worker_count = int(worker_count)
aggregate_floor = int(aggregate_floor)
worker_floor = int(worker_floor)
worker_ceiling = int(worker_ceiling)


def fail(reason):
    raise SystemExit(f"A_HEALTHY=0 ready=no REASON={reason}")


def proc(pid):
    try:
        fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    except OSError:
        fail(f"PROC_MISSING pid={pid}")
    return {"pid": pid, "state": fields[2], "pgid": int(fields[4]), "start_ticks": int(fields[21])}


def pss_kib(pid):
    try:
        for line in pathlib.Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        return 0
    return 0


if not pid_file.isdigit() and not pathlib.Path(pid_file).exists():
    fail("PID_FILE_MISSING")
pid = int(pid_file) if pid_file.isdigit() else int(pathlib.Path(pid_file).read_text().strip())
service_path = state_root / "service.json"
health_path = state_root / "health.json"
if not service_path.exists() or not health_path.exists():
    fail("SERVICE_STATE_MISSING")
service = json.loads(service_path.read_text())
if service.get("pid") != pid:
    fail("SUPERVISOR_PID_MISMATCH")
identity = proc(pid)
if identity["state"] in {"T", "Z", "X"} or identity["start_ticks"] != service.get("start_ticks"):
    fail("SUPERVISOR_IDENTITY_OR_STATE")
if int(service.get("worker_count", 0)) != worker_count or len(service.get("worker_pids", [])) != worker_count:
    fail("WORKER_ROSTER_SIZE")

with urllib.request.urlopen(f"http://{host}:{port}/canary", timeout=8) as response:
    canary = json.loads(response.read().decode("utf-8"))
if not canary.get("ok") or canary.get("checksum") != expected_checksum:
    fail("CANARY_CHECKSUM")

pss_values = {"supervisor": pss_kib(pid)}
units = []
for index, worker_pid in enumerate(service["worker_pids"]):
    wid = proc(int(worker_pid))
    if wid["state"] in {"T", "Z", "X"} or wid["start_ticks"] != service["worker_start_ticks"][index]:
        fail(f"WORKER_IDENTITY_OR_STATE worker={index}")
    ledger_path = state_root / "workers" / f"worker-{index}.json"
    if not ledger_path.exists():
        fail(f"WORKER_LEDGER_MISSING worker={index}")
    ledger = json.loads(ledger_path.read_text())
    if ledger.get("pid") != worker_pid or ledger.get("start_ticks") != service["worker_start_ticks"][index]:
        fail(f"WORKER_LEDGER_IDENTITY worker={index}")
    if time.time() - float(ledger.get("heartbeat", 0.0)) > 6.0:
        fail(f"WORKER_HEARTBEAT_STALE worker={index}")
    worker_pss = pss_kib(int(worker_pid))
    pss_values[f"worker_{index}"] = worker_pss
    if worker_pss < worker_floor:
        fail(f"WORKER_PSS_BELOW_FLOOR worker={index} pss_kib={worker_pss}")
    if worker_pss > worker_ceiling:
        fail(f"WORKER_PSS_ABOVE_CEILING worker={index} pss_kib={worker_pss}")
    units.append(int(ledger.get("served_batches", 0)))

aggregate = sum(pss_values.values())
if aggregate < aggregate_floor:
    fail(f"AGGREGATE_PSS_BELOW_FLOOR aggregate_pss_kib={aggregate}")

print(
    "A_HEALTHY=1 ready=yes pid={} workers={} aggregate_pss_kib={} supervisor_pss_kib={} "
    "canary_count={} checksum={} worker_served={}".format(
        pid,
        worker_count,
        aggregate,
        pss_values["supervisor"],
        canary.get("canary_count"),
        canary.get("checksum"),
        ",".join(str(value) for value in units),
    )
)
PY
