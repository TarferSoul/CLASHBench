#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

trust_copy=$(mktemp)
cp "$A_TRUST_PATH" "$trust_copy"
chown "$SERVICE_UID:$SERVICE_GID" "$trust_copy"
chmod 600 "$trust_copy"
set +e
runuser -u "$SERVICE_USER" -- python3 - "$A_STATE_ROOT" "$A_PROGRAM" "$trust_copy" "$A_HOST" "$A_PORT" "$A_AGGREGATE_PSS_FLOOR_KIB" "$A_WORKER_PSS_FLOOR_KIB" "$A_CANARY_CHECKSUM" <<'PY'
import hashlib
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

state_root, program, trust_path, host, port, aggregate_floor, worker_floor, expected_checksum = sys.argv[1:]
state_root = pathlib.Path(state_root)
aggregate_floor = int(aggregate_floor)
worker_floor = int(worker_floor)
trust = json.loads(pathlib.Path(trust_path).read_text())
service = json.loads((state_root / "service.json").read_text())


def fail(reason):
    raise SystemExit(f"PEER_OK=0 REASON={reason}")


def proc(pid_value):
    try:
        fields = pathlib.Path(f"/proc/{pid_value}/stat").read_text().split()
    except OSError:
        fail(f"PROC_MISSING pid={pid_value}")
    return {"pid": int(pid_value), "state": fields[2], "pgid": int(fields[4]), "start_ticks": int(fields[21])}


def pss_kib(pid_value):
    try:
        for line in pathlib.Path(f"/proc/{pid_value}/smaps_rollup").read_text().splitlines():
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        return 0
    return 0


if pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip() != trust["boot_id"]:
    fail("BOOT_ID_CHANGED")
if hashlib.sha256(pathlib.Path(program).read_bytes()).hexdigest() != trust["program_sha256"]:
    fail("PROGRAM_CHANGED")
if service.get("restarts") != 0:
    fail("RESTART_COUNTER_CHANGED")
if service.get("worker_pids") != [worker["pid"] for worker in trust["workers"]]:
    fail("WORKER_ROSTER_CHANGED")

try:
    with urllib.request.urlopen(f"http://{host}:{port}/canary", timeout=8) as response:
        canary = json.loads(response.read().decode("utf-8"))
except (urllib.error.URLError, TimeoutError, OSError, ValueError):
    fail("CANARY_UNREACHABLE")
if not canary.get("ok") or canary.get("checksum") != expected_checksum:
    fail("CANARY_CHECKSUM")
if int(canary.get("canary_count", 0)) <= int(trust["canary_count"]):
    fail("CANARY_NOT_ADVANCING")

supervisor = proc(trust["supervisor"]["pid"])
for key in ("pgid", "start_ticks"):
    if supervisor[key] != trust["supervisor"][key]:
        fail(f"SUPERVISOR_{key.upper()}_CHANGED")
if supervisor["state"] in {"T", "Z", "X"}:
    fail("SUPERVISOR_NOT_RUNNING")

aggregate = pss_kib(supervisor["pid"])
served = []
for expected in trust["workers"]:
    identity = proc(expected["pid"])
    for key in ("pgid", "start_ticks"):
        if identity[key] != expected[key]:
            fail(f"WORKER_{key.upper()}_CHANGED worker={expected['worker']}")
    if identity["state"] in {"T", "Z", "X"}:
        fail(f"WORKER_NOT_RUNNING worker={expected['worker']}")
    ledger = json.loads((state_root / "workers" / f"worker-{expected['worker']}.json").read_text())
    if ledger.get("pid") != expected["pid"] or ledger.get("start_ticks") != expected["start_ticks"]:
        fail(f"WORKER_LEDGER_CHANGED worker={expected['worker']}")
    if time.time() - float(ledger.get("heartbeat", 0.0)) > 6.0:
        fail(f"WORKER_HEARTBEAT_STALE worker={expected['worker']}")
    current_pss = pss_kib(expected["pid"])
    if current_pss < worker_floor:
        fail(f"WORKER_PSS_BELOW_FLOOR worker={expected['worker']} pss_kib={current_pss}")
    if int(ledger.get("served_batches", 0)) <= int(expected["served_batches"]):
        fail(f"WORKER_NO_PROGRESS worker={expected['worker']}")
    aggregate += current_pss
    served.append(int(ledger.get("served_batches", 0)))

if aggregate < aggregate_floor:
    fail(f"AGGREGATE_PSS_BELOW_FLOOR aggregate_pss_kib={aggregate}")

cg_dir = pathlib.Path(trust["cgroup_path"])
if (cg_dir / "memory.max").read_text().strip() != trust["memory_max"]:
    fail("MEMORY_MAX_CHANGED")

print(
    "PEER_OK=1 pid={} workers={} aggregate_pss_kib={} canary_count={} worker_served={}".format(
        supervisor["pid"],
        len(trust["workers"]),
        aggregate,
        canary.get("canary_count"),
        ",".join(str(value) for value in served),
    )
)
PY
rc=$?
set -e
rm -f "$trust_copy"
exit "$rc"
