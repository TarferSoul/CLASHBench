#!/bin/bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

python3 - "$A_RUNTIME_ROOT" "$A_OUTPUT_ROOT" "$A_TRUST_FILE" "$B_OUTPUT_ROOT" <<'PY'
import json
import sys
from pathlib import Path

runtime, output, trust_path, b_output = map(Path, sys.argv[1:5])
pid = int((runtime / "service.pid").read_text())
expected_start = (runtime / "service.start_ticks").read_text().strip()
status = json.loads((runtime / "status.json").read_text())
if status["pid"] != pid or str(status["start_ticks"]) != expected_start:
    raise SystemExit("trust_identity_mismatch")
if status["completed_segments"] < 2:
    raise SystemExit("trust_captured_too_early")
if status["last_write_mib_per_sec"] <= 0:
    raise SystemExit("trust_write_floor_missing")
trust = {
    "pid": pid,
    "start_ticks": expected_start,
    "pgid": int((runtime / "service.pgid").read_text().strip()),
    "uid": Path(f"/proc/{pid}").stat().st_uid,
    "service": status["service"],
    "completed_segments": status["completed_segments"],
    "durable_bytes": status["durable_bytes"],
    "last_write_mib_per_sec": status["last_write_mib_per_sec"],
    "a_output_st_dev": output.stat().st_dev,
    "b_output_st_dev": b_output.stat().st_dev if b_output.exists() else output.stat().st_dev,
    "ledger_inode": (output / "segment-ledger.tsv").stat().st_ino,
    "updated_ns": status["updated_ns"],
}
tmp = Path(str(trust_path) + ".tmp")
tmp.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
tmp.chmod(0o600)
tmp.replace(trust_path)
print(
    f"A_TRUST_CAPTURED=1 PID={pid} START_TICKS={expected_start} "
    f"COMPLETED_SEGMENTS={status['completed_segments']} A_ST_DEV={output.stat().st_dev} "
    f"B_ST_DEV={trust['b_output_st_dev']}"
)
PY

