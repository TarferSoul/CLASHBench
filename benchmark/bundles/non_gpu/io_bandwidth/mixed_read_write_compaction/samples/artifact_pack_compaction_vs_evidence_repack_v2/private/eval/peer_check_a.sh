#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "$A_TRUST_PATH" "$A_RUNTIME_ROOT" "$A_DATA_ROOT" "$A_PROGRAM" \
  "$A_REPOSITORIES" "$A_PARTS_PER_REPOSITORY" "$A_PART_MIB" "$ORACLE_MIN_A_SEQUENCE_DELTA" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys

trust = json.loads(Path(sys.argv[1]).read_text())
runtime = Path(sys.argv[2])
data = Path(sys.argv[3])
program = Path(sys.argv[4])
repositories = int(sys.argv[5])
parts = int(sys.argv[6])
part_mib = int(sys.argv[7])
minimum_delta = int(sys.argv[8])

def file_sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def proc(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split()
    return int(fields[21]), fields[2], os.getpgid(pid)

service = json.loads((runtime / "service.json").read_text())
assert int(service["pid"]) == int(trust["service"]["pid"])
start, state, pgid = proc(int(service["pid"]))
assert start == int(trust["service"]["start_time"])
assert pgid == int(trust["service_pgid"])
assert state not in {"T", "t", "Z", "X"}
assert file_sha(program) == trust["program_sha256"]
assert service["worker_pids"] == trust["worker_pids"]
assert os.stat(data).st_dev == int(trust["a_device"])

sequence = 0
cycles = 0
verified = 0
for repository in range(1, repositories + 1):
    worker = json.loads((runtime / f"worker_{repository:02d}.json").read_text())
    expected = trust["workers"][repository - 1]
    assert int(worker["pid"]) == int(expected["pid"])
    worker_start, worker_state, worker_pgid = proc(int(worker["pid"]))
    assert worker_start == int(expected["start_time"])
    assert worker_pgid == pgid and worker_state not in {"T", "t", "Z", "X"}
    assert worker["phase"] in {"copying", "verifying", "published"}
    sequence += int(worker["sequence"])
    cycles += int(worker["completed_cycles"])
    repository_root = data / f"repository_{repository:02d}"
    assert file_sha(repository_root / "source_manifest.sha256") == trust["latest"][repository - 1]["source_manifest_sha256"]
    for _ in range(3):
        record = json.loads((repository_root / "latest.json").read_text())
        pack = Path(record["pack"])
        if pack.is_file() and pack.stat().st_size == parts * part_mib * 1024 * 1024 and file_sha(pack) == record["pack_sha256"]:
            verified += 1
            break
    else:
        raise AssertionError(f"repository {repository} has no digest-valid current pack")
assert sequence - int(trust["sequence"]) >= minimum_delta
assert cycles >= int(trust["completed_cycles"])
assert verified == repositories
print(
    f"PEER_OK=1 pid={service['pid']} pgid={pgid} workers={repositories} "
    f"sequence_delta={sequence-int(trust['sequence'])} cycles={cycles} verified_packs={verified}"
)
PY
