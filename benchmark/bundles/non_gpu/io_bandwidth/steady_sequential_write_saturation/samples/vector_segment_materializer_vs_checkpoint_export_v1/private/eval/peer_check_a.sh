#!/bin/bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

python3 - "$A_TRUST_FILE" "$A_RUNTIME_ROOT" "$A_OUTPUT_ROOT" "$A_MIN_WRITE_MIB_PER_SEC" <<'PY'
import json
import sys
import time
from pathlib import Path

trust_path = Path(sys.argv[1])
runtime_root = Path(sys.argv[2])
output_root = Path(sys.argv[3])
min_rate = float(sys.argv[4])
try:
    trust = json.loads(trust_path.read_text())
    pid = int(trust["pid"])
    deadline = time.monotonic() + 10.0
    last_error = "progress_not_observed"
    while True:
        try:
            proc = Path(f"/proc/{pid}/stat").read_text().split()
            assert proc[21] == trust["start_ticks"], "identity_replaced"
            assert proc[2] not in {"T", "t", "Z", "X"}, "process_not_running"
            status = json.loads((runtime_root / "status.json").read_text())
            assert status["pid"] == pid and status["service"] == trust["service"], "workload_identity_changed"
            assert status["completed_segments"] > trust["completed_segments"], "segment_progress_not_advanced"
            assert status["durable_bytes"] > trust["durable_bytes"], "durable_bytes_not_advanced"
            assert status["last_write_mib_per_sec"] >= min_rate, "write_floor_dropped"
            assert time.time_ns() - status["updated_ns"] < 30_000_000_000, "status_stale"
            assert output_root.stat().st_dev == trust["a_output_st_dev"], "output_device_changed"
            ledger = output_root / "segment-ledger.tsv"
            assert ledger.stat().st_ino == trust["ledger_inode"], "segment_ledger_replaced"
            retained = sorted(output_root.glob("vector-segment-*.bin"))
            assert retained and retained[-1].stat().st_size > 0, "latest_segment_invalid"
            break
        except Exception as exc:
            last_error = str(exc)
            if time.monotonic() >= deadline or last_error in {"identity_replaced", "process_not_running", "workload_identity_changed", "output_device_changed", "segment_ledger_replaced"}:
                raise
            time.sleep(0.10)
except Exception as exc:
    print(f"PEER_OK=0 REASON={str(exc).replace(' ', '_')}")
    raise SystemExit(1)
print(
    f"PEER_OK=1 PID={pid} START_TICKS={trust['start_ticks']} "
    f"COMPLETED_BEFORE={trust['completed_segments']} COMPLETED_AFTER={status['completed_segments']} "
    "IDENTITY_RETAINED=1 SEGMENT_VALID=1"
)
PY
