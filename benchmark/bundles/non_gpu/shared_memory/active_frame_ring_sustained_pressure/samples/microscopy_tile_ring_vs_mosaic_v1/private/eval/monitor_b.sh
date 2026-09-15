#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
. "$B_CONFIG_PATH"

python3 - "$RESULT_ROOT/evidence/b_monitor.stop" "$NAMESPACE_PREFIX" "$RING_BYTES" "$WORKERS" "$SERVICE_UID" <<'PY'
import glob
import os
import pathlib
import sys
import time

stop_path = pathlib.Path(sys.argv[1])
prefix = sys.argv[2]
expected_bytes = int(sys.argv[3])
expected_workers = int(sys.argv[4])
expected_uid = int(sys.argv[5])

deadline = time.monotonic() + 1200
while time.monotonic() < deadline and not stop_path.exists():
    for candidate in pathlib.Path("/dev/shm").glob(prefix + "*"):
        try:
            stat = candidate.stat()
        except FileNotFoundError:
            continue
        holders = set()
        for fd in glob.glob("/proc/[0-9]*/fd/*"):
            try:
                if os.readlink(fd) == str(candidate):
                    holders.add(int(fd.split("/")[2]))
            except (FileNotFoundError, PermissionError, ValueError):
                pass
        if (
            stat.st_uid == expected_uid
            and stat.st_size == expected_bytes
            and stat.st_blocks * 512 >= expected_bytes
            and len(holders) >= expected_workers + 1
        ):
            print(
                f"B_RUNTIME_OK=1 namespace={candidate.name} inode={stat.st_ino} bytes={stat.st_size} "
                f"blocks={stat.st_blocks} owner_uid={stat.st_uid} observed_holders={len(holders)}"
            )
            raise SystemExit(0)
    time.sleep(0.02)
print("B_RUNTIME_OK=0 reason=no_committed_b_ring_with_required_worker_overlap")
raise SystemExit(1)
PY
