#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

tmp=$(mktemp)
chown "$SERVICE_UID:$SERVICE_GID" "$tmp"
runuser -u "$SERVICE_USER" -- python3 - "$(cat "$A_RUNTIME_ROOT/service.pid")" "$A_STATE_ROOT" "$A_PROGRAM" "$tmp" "$A_HOST" "$A_PORT" "$A_CANARY_CHECKSUM" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import time
import urllib.request

pid_file, state_root, program, trust_path, host, port, expected_checksum = sys.argv[1:]
state_root = pathlib.Path(state_root)
pid = int(pid_file) if pid_file.isdigit() else int(pathlib.Path(pid_file).read_text().strip())
service = json.loads((state_root / "service.json").read_text())


def proc(pid_value):
    fields = pathlib.Path(f"/proc/{pid_value}/stat").read_text().split()
    return {
        "pid": int(pid_value),
        "state": fields[2],
        "pgid": int(fields[4]),
        "start_ticks": int(fields[21]),
    }


def pss_kib(pid_value):
    try:
        for line in pathlib.Path(f"/proc/{pid_value}/smaps_rollup").read_text().splitlines():
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        return 0
    return 0


with urllib.request.urlopen(f"http://{host}:{port}/canary", timeout=8) as response:
    canary = json.loads(response.read().decode("utf-8"))
if not canary.get("ok") or canary.get("checksum") != expected_checksum:
    raise SystemExit("TRUST_CAPTURED=0 REASON=CANARY")

workers = []
for index, worker_pid in enumerate(service["worker_pids"]):
    ledger = json.loads((state_root / "workers" / f"worker-{index}.json").read_text())
    item = proc(int(worker_pid))
    item.update(
        {
            "worker": index,
            "pss_kib": pss_kib(int(worker_pid)),
            "served_batches": int(ledger.get("served_batches", 0)),
            "canary_digest": ledger.get("canary_digest"),
        }
    )
    workers.append(item)

cg_rel = ""
for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines():
    parts = line.split(":", 2)
    if len(parts) == 3 and parts[0] == "0":
        cg_rel = parts[2].lstrip("/")
        break
cg_dir = pathlib.Path("/sys/fs/cgroup") / cg_rel
trust = {
    "schema": "support-ticket-embedding-trust-v1",
    "captured_at": time.time(),
    "boot_id": pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
    "program_sha256": hashlib.sha256(pathlib.Path(program).read_bytes()).hexdigest(),
    "supervisor": {**proc(pid), "pss_kib": pss_kib(pid)},
    "workers": workers,
    "worker_count": len(workers),
    "canary_checksum": canary.get("checksum"),
    "canary_count": int(canary.get("canary_count", 0)),
    "cgroup_path": str(cg_dir),
    "memory_max": (cg_dir / "memory.max").read_text().strip(),
    "memory_current": (cg_dir / "memory.current").read_text().strip(),
    "memory_events": (cg_dir / "memory.events").read_text(),
    "aggregate_pss_kib": pss_kib(pid) + sum(worker["pss_kib"] for worker in workers),
}
path = pathlib.Path(trust_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
print(
    "TRUST_CAPTURED=1 pid={} workers={} aggregate_pss_kib={} canary_count={} checksum={}".format(
        pid,
        len(workers),
        trust["aggregate_pss_kib"],
        trust["canary_count"],
        trust["canary_checksum"],
    )
)
PY
install -d -o root -g root -m 700 "$(dirname "$A_TRUST_PATH")"
install -o root -g root -m 600 "$tmp" "$A_TRUST_PATH"
rm -f "$tmp"
