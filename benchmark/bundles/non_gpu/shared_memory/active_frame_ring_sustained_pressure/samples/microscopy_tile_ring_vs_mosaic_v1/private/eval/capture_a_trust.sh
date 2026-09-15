#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"

python3 - "$A_META_PATH" "$A_HEALTH_PATH" "$TRUST_ROOT/a.json" <<'PY'
import json
import os
import pathlib
import sys

meta_path, health_path, output = map(pathlib.Path, sys.argv[1:])
meta = json.loads(meta_path.read_text())
health = json.loads(health_path.read_text())

def start_ticks(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(text[text.rfind(")") + 2:].split()[19])

ring = (pathlib.Path("/dev/shm") / meta["ring_name"]).stat()
trust = {
    "pid": meta["pid"],
    "start_ticks": start_ticks(meta["pid"]),
    "worker_one_pid": meta["worker_one_pid"],
    "worker_one_start_ticks": start_ticks(meta["worker_one_pid"]),
    "worker_two_pid": meta["worker_two_pid"],
    "worker_two_start_ticks": start_ticks(meta["worker_two_pid"]),
    "worker_one_name": meta["worker_one_name"],
    "worker_two_name": meta["worker_two_name"],
    "ring_name": meta["ring_name"],
    "ring_inode": ring.st_ino,
    "ring_bytes": ring.st_size,
    "ring_blocks": ring.st_blocks,
    "slots": meta["slots"],
    "item_bytes": meta["item_bytes"],
    "producer_seq": health["producer_seq"],
    "worker_one_seq": health["worker_one_seq"],
    "worker_two_seq": health["worker_two_seq"],
    "valid_items": health["valid_items"],
}
output.write_text(json.dumps(trust, sort_keys=True) + "\n")
os.chmod(output, 0o600)
print(
    f"A_TRUST=1 pid={trust['pid']} ring_inode={trust['ring_inode']} ring_bytes={trust['ring_bytes']} "
    f"producer_seq={trust['producer_seq']} consumers={trust['worker_one_name']},{trust['worker_two_name']}"
)
PY
