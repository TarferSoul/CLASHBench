#!/bin/bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

python3 - "$A_STATUS_FILE" "$A_MIN_WRITE_MIB_PER_SEC" <<'PY'
import json
import sys
import time
from pathlib import Path

status_path = Path(sys.argv[1])
min_rate = float(sys.argv[2])
status = json.loads(status_path.read_text())
pid = int(status["pid"])
proc = Path(f"/proc/{pid}/stat").read_text().split()
if proc[21] != str(status["start_ticks"]):
    raise SystemExit("A_STATUS_FAIL=identity_mismatch")
if proc[2] in {"T", "t", "Z", "X"}:
    raise SystemExit("A_STATUS_FAIL=not_running")
if int(status["completed_segments"]) < 2:
    raise SystemExit("A_STATUS_WAIT=segments")
if float(status["last_write_mib_per_sec"]) < min_rate:
    raise SystemExit("A_STATUS_WAIT=write_floor")
if time.time_ns() - int(status["updated_ns"]) > 30_000_000_000:
    raise SystemExit("A_STATUS_FAIL=status_stale")
print(
    "A_STATUS_OK=1 PID=%s COMPLETED_SEGMENTS=%s DURABLE_BYTES=%s LAST_WRITE_MIB_PER_SEC=%s"
    % (pid, status["completed_segments"], status["durable_bytes"], status["last_write_mib_per_sec"])
)
PY

