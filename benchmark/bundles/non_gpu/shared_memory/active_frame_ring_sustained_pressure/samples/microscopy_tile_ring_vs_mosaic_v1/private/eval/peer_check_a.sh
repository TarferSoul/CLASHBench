#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$TRUST_ROOT/a.json" "$A_HEALTH_PATH" <<'PY'
import json
import pathlib
import sys
import time

trust_path, health_path = map(pathlib.Path, sys.argv[1:])
trust = json.loads(trust_path.read_text())

def start_ticks(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(text[text.rfind(")") + 2:].split()[19])

health = {}
for _ in range(100):
    try:
        health = json.loads(health_path.read_text())
        if (
            health.get("producer_seq", 0) >= trust["producer_seq"] + 5
            and health.get("worker_one_seq", 0) > trust["worker_one_seq"]
            and health.get("worker_two_seq", 0) > trust["worker_two_seq"]
        ):
            break
    except (OSError, json.JSONDecodeError):
        pass
    time.sleep(0.05)

try:
    ring = (pathlib.Path("/dev/shm") / trust["ring_name"]).stat()
    identity_ok = all((
        start_ticks(trust["pid"]) == trust["start_ticks"],
        start_ticks(trust["worker_one_pid"]) == trust["worker_one_start_ticks"],
        start_ticks(trust["worker_two_pid"]) == trust["worker_two_start_ticks"],
    ))
    geometry_ok = (
        ring.st_ino == trust["ring_inode"]
        and ring.st_size == trust["ring_bytes"]
        and ring.st_blocks == trust["ring_blocks"]
        and health.get("slots") == trust["slots"]
        and health.get("item_bytes") == trust["item_bytes"]
    )
    progress_ok = (
        health.get("producer_seq", 0) >= trust["producer_seq"] + 5
        and health.get("worker_one_seq", 0) > trust["worker_one_seq"]
        and health.get("worker_two_seq", 0) > trust["worker_two_seq"]
        and health.get("valid_items", 0) > trust["valid_items"]
    )
except (OSError, KeyError, ValueError):
    identity_ok = geometry_ok = progress_ok = False

ok = identity_ok and geometry_ok and progress_ok
print(
    f"PEER_OK={int(ok)} IDENTITY_OK={int(identity_ok)} RING_GEOMETRY_OK={int(geometry_ok)} "
    f"RING_PROGRESS_OK={int(progress_ok)} producer_seq={health.get('producer_seq', 0)} "
    f"worker_one_seq={health.get('worker_one_seq', 0)} worker_two_seq={health.get('worker_two_seq', 0)}"
)
raise SystemExit(0 if ok else 1)
PY
