#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
install -d -o root -g root -m 700 "$(dirname "$A_TRUST_PATH")"
python3 - "$A_RUNTIME_ROOT" "$A_DATA_ROOT" "$A_PROGRAM" "$A_TRUST_PATH" \
  "$A_REPOSITORIES" "$B_INPUT_REAL" "$B_OUTPUT_REAL" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys
import time

runtime = Path(sys.argv[1])
data = Path(sys.argv[2])
program = Path(sys.argv[3])
output = Path(sys.argv[4])
repositories = int(sys.argv[5])
b_input = Path(sys.argv[6])
b_output = Path(sys.argv[7])

def file_sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def proc(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split()
    return {"pid": pid, "start_time": int(fields[21]), "state": fields[2], "pgid": os.getpgid(pid)}

service = json.loads((runtime / "service.json").read_text())
workers = []
sequence = 0
cycles = 0
latest = []
for repository in range(1, repositories + 1):
    state = json.loads((runtime / f"worker_{repository:02d}.json").read_text())
    identity = proc(int(state["pid"]))
    identity["repository"] = repository
    workers.append(identity)
    sequence += int(state["sequence"])
    cycles += int(state["completed_cycles"])
    record = json.loads((data / f"repository_{repository:02d}" / "latest.json").read_text())
    latest.append({
        "repository": repository,
        "cycle": record["cycle"],
        "pack": record["pack"],
        "pack_sha256": record["pack_sha256"],
        "record_sha256": record["record_sha256"],
        "source_manifest_sha256": file_sha(data / f"repository_{repository:02d}" / "source_manifest.sha256"),
    })

trust = {
    "captured_at": time.time(),
    "service": proc(int(service["pid"])),
    "service_pgid": int(service["pgid"]),
    "workers": workers,
    "worker_pids": service["worker_pids"],
    "program": str(program),
    "program_sha256": file_sha(program),
    "a_data_root": str(data.resolve()),
    "b_input_root": str(b_input.resolve()),
    "b_output_root": str(b_output.resolve()),
    "a_device": os.stat(data).st_dev,
    "b_input_device": os.stat(b_input).st_dev,
    "b_output_device": os.stat(b_output).st_dev,
    "sequence": sequence,
    "completed_cycles": cycles,
    "latest": latest,
}
temporary = output.with_name(f".{output.name}.tmp.{os.getpid()}")
temporary.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
os.chmod(temporary, 0o600)
os.replace(temporary, output)
print(
    f"A_TRUST_OK=1 pid={service['pid']} pgid={service['pgid']} workers={len(workers)} "
    f"cycles={cycles} sequence={sequence} device={trust['a_device']}"
)
PY
