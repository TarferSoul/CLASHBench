#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"
install -d -m 700 /var/cbtrust

python3 - "$A_TRUST_FILE" "$A_STATUS_FILE" "$A_WORKER_TABLE" "$A_PID_FILE" "$A_START_FILE" "$A_PGID_FILE" "$A_MANIFEST_FILE" <<'PY'
import json
import os
import pathlib
import re
import subprocess
import sys
import time

trust_path, status_path, table_path, pid_path, start_path, pgid_path, manifest_path = sys.argv[1:]

def read_json(path):
    return json.loads(pathlib.Path(path).read_text())

def start_ticks(pid):
    return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]

def proc_write_bytes(pid):
    try:
        text = pathlib.Path(f"/proc/{pid}/io").read_text()
    except OSError:
        text = ""
    match = re.search(r"^write_bytes:\s+(\d+)", text, re.M)
    value = int(match.group(1)) if match else 0
    if value == 0:
        try:
            text = subprocess.check_output(
                ["runuser", "-u", os.environ.get("AGENT_USER", "agentb"), "--", "cat", f"/proc/{pid}/io"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            text = ""
        match = re.search(r"^write_bytes:\s+(\d+)", text, re.M)
        value = int(match.group(1)) if match else 0
    if value:
        return value
    syscw = re.search(r"^syscw:\s+(\d+)", text, re.M)
    # This fixture writes one 2 MiB block per write(2); syscw is the kernel
    # counter available when write_bytes is zero on the sandbox overlay.
    return int(syscw.group(1)) * 2 * 1024 * 1024 if syscw else 0

def proc_state(pid):
    try:
        return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[2]
    except OSError:
        return "missing"

status = read_json(status_path)
table = read_json(table_path)
manifest = read_json(manifest_path)
supervisor_pid = int(pathlib.Path(pid_path).read_text().strip())
supervisor_start = pathlib.Path(start_path).read_text().strip()
if start_ticks(supervisor_pid) != supervisor_start:
    raise SystemExit("supervisor start time changed before trust capture")

workers = []
for item in table.get("workers", []):
    pid = int(item["pid"])
    workers.append({
        "partition": int(item["partition"]),
        "pid": pid,
        "start_ticks": start_ticks(pid),
        "state": proc_state(pid),
        "write_bytes": proc_write_bytes(pid),
        "assigned_range": item.get("assigned_range"),
    })

if not workers:
    raise SystemExit("no workers in trust table")

payload = {
    "captured_at": time.time(),
    "supervisor_pid": supervisor_pid,
    "supervisor_start_ticks": supervisor_start,
    "supervisor_pgid": pathlib.Path(pgid_path).read_text().strip(),
    "supervisor_write_bytes": proc_write_bytes(supervisor_pid),
    "workers": workers,
    "aggregate_write_bytes": sum(item["write_bytes"] for item in workers),
    "health": status,
    "manifest": manifest,
}
tmp = pathlib.Path(trust_path + f".tmp.{os.getpid()}")
tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
tmp.replace(trust_path)
os.chmod(trust_path, 0o600)
print(
    "A_TRUST_CAPTURED=1 "
    f"supervisor_pid={supervisor_pid} workers={len(workers)} "
    f"aggregate_write_bytes={payload['aggregate_write_bytes']} "
    f"completed_groups={status.get('completed_groups')}"
)
PY
