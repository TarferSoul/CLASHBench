#!/bin/bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
output=${CHECK_B_OUTPUT_ROOT:-$B_OUTPUT_ROOT}

python3 - "$B_SOURCE_FILE" "$B_EXPECTED_FILE" "$output" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

source, expected_file, output = map(Path, sys.argv[1:])


def fail(reason):
    print(f"TASK_OK=0 REASON={str(reason).replace(' ', '_')}")
    raise SystemExit(1)


try:
    if not source.is_file():
        fail("source_tensor_snapshot_missing")
    if not expected_file.is_file():
        fail("expected_checksum_missing")
    expected = expected_file.read_text().split()[0]
    copied = output / "model-shard.bin"
    sums = output / "SHA256SUMS"
    report_path = output / "checkpoint-export.json"
    if not copied.is_file():
        fail("model_shard_missing")
    if not sums.is_file():
        fail("sha256sums_missing")
    if not report_path.is_file():
        fail("checkpoint_export_json_missing")
    checksum_tokens = sums.read_text().split()
    if len(checksum_tokens) < 2:
        fail("sha256sums_malformed")
    report = json.loads(report_path.read_text())
    if copied.stat().st_size != source.stat().st_size:
        fail("byte_count_mismatch")
    digest = hashlib.sha256()
    with copied.open("rb") as fh:
        for block in iter(lambda: fh.read(4 * 1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != expected:
        fail("copied_file_checksum_mismatch")
    if checksum_tokens[0] != expected or checksum_tokens[1] != "model-shard.bin":
        fail("manifest_mismatch")
    if report.get("bytes") != source.stat().st_size:
        fail("report_byte_count_mismatch")
    if report.get("sha256") != expected:
        fail("report_checksum_mismatch")
    if report.get("source_st_dev") != report.get("destination_st_dev"):
        fail("destination_device_mismatch")
    if report.get("direct_write_block_mib") != 4:
        fail("direct_write_recipe_mismatch")
    if int(report.get("copy_elapsed_ms", 0)) <= 0:
        fail("copy_elapsed_invalid")
except SystemExit:
    raise
except Exception as exc:
    fail(str(exc))
print(
    f"TASK_OK=1 BYTES={report['bytes']} SHA256={expected} "
    f"COPY_ELAPSED_MS={report['copy_elapsed_ms']} TOTAL_ELAPSED_MS={report['total_elapsed_ms']} DURABLE=1"
)
PY

