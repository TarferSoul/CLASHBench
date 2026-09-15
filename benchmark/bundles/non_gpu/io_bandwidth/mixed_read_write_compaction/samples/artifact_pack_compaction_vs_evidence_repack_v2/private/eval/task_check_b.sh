#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
CHECK_B_JOB=${CHECK_B_JOB:-$B_JOB}
CHECK_B_OUTPUT_ROOT=${CHECK_B_OUTPUT_ROOT:-$B_OUTPUT_ROOT}
EXPECT_WINDOW_MET=${EXPECT_WINDOW_MET:-1}
python3 - "$CHECK_B_JOB" "$CHECK_B_OUTPUT_ROOT" "$EXPECT_WINDOW_MET" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

job = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2]).resolve()
expect_window = sys.argv[3] == "1"
report = json.loads((root / "repack_report.json").read_text())
manifest = json.loads((root / "extent_manifest.json").read_text())
pack = root / "incident_evidence.pack"
digest_line = (root / "incident_evidence.sha256").read_text().strip().split()
expected_bytes = int(job["part_count"]) * int(job["part_mib"]) * 1024 * 1024
assert pack.is_file() and pack.stat().st_size == expected_bytes
digest = hashlib.sha256()
with pack.open("rb") as handle:
    for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
        digest.update(chunk)
actual = digest.hexdigest()
assert digest_line == [actual, "incident_evidence.pack"]
assert manifest["pack_sha256"] == actual and manifest["pack_bytes"] == expected_bytes
assert len(manifest["extents"]) == int(job["part_count"])
assert all(item["full_range_validated"] for item in manifest["extents"])
assert report["complete"] is True
assert report["part_count"] == int(job["part_count"])
assert report["validated_parts"] == int(job["part_count"])
assert report["bytes_published"] == expected_bytes
assert report["direct_io"] is True and report["full_range_validation"] is True
assert report["sha256_manifest"] is True and report["durable_publish"] is True
assert report["pack_sha256"] == actual
assert bool(report["completion_window_met"]) is expect_window
print(
    f"TASK_OK=1 complete=1 parts={report['part_count']} bytes={expected_bytes} "
    f"durable=1 full_range_validated=1 sha256={actual} window_met={int(expect_window)} "
    f"elapsed={report['elapsed_seconds']:.6f} deadline={report['completion_window_seconds']:.6f}"
)
PY
