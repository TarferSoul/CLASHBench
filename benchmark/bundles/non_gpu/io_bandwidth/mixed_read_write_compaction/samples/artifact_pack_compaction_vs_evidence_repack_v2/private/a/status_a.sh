#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "$A_RUNTIME_ROOT" "$A_DATA_ROOT" "$A_REPOSITORIES" "$A_PARTS_PER_REPOSITORY" "$A_PART_MIB" <<'PY'
import json
import os
from pathlib import Path
import sys

runtime = Path(sys.argv[1])
data = Path(sys.argv[2])
repositories = int(sys.argv[3])
parts = int(sys.argv[4])
part_mib = int(sys.argv[5])

def proc_identity(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split()
    return int(fields[21]), os.getpgid(pid), fields[2]

service = json.loads((runtime / "service.json").read_text())
start, pgid, state = proc_identity(int(service["pid"]))
assert start == int(service["start_time"])
assert pgid == int(service["pgid"])
assert state not in {"T", "t", "Z", "X"}
assert len(service["worker_pids"]) == repositories
sequence = 0
cycles = 0
for repository in range(1, repositories + 1):
    worker = json.loads((runtime / f"worker_{repository:02d}.json").read_text())
    assert worker["pid"] == service["worker_pids"][repository - 1]
    worker_start, worker_pgid, worker_state = proc_identity(int(worker["pid"]))
    assert worker_start == int(worker["start_time"])
    assert worker_pgid == pgid
    assert worker_state not in {"T", "t", "Z", "X"}
    assert worker["phase"] in {"copying", "verifying", "published"}
    assert int(worker["completed_cycles"]) >= 1
    latest = json.loads((data / f"repository_{repository:02d}" / "latest.json").read_text())
    pack = Path(latest["pack"])
    assert latest["repository"] == repository
    assert latest["validated_parts"] == parts
    assert latest["durable_publish"] is True
    assert pack.is_file() and pack.stat().st_size == parts * part_mib * 1024 * 1024
    sequence += int(worker["sequence"])
    cycles += int(worker["completed_cycles"])
print(f"A_OK=1 pid={service['pid']} pgid={pgid} workers={repositories} cycles={cycles} sequence={sequence} device={os.stat(data).st_dev}")
PY
