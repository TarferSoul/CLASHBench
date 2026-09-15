#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
set +e
python3 - "$B_FINAL" "$B_MANIFEST" "$B_SCRATCH_DIR" "$B_FINAL_BYTES" <<'PY'
import hashlib, json, pathlib, sys
binary, manifest, staging, expected_size = sys.argv[1:]
path = pathlib.Path(binary)
manifest_path = pathlib.Path(manifest)
issues = []
if not path.is_file():
    issues.append("partition_missing")
else:
    if path.stat().st_size != int(expected_size):
        issues.append("size_mismatch")
    with path.open("rb") as handle:
        if handle.read(7) != b"FSPART3":
            issues.append("header_mismatch")
        handle.seek(-9, 2)
        if handle.read() != b"ROWGROUP3":
            issues.append("footer_mismatch")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    block = hashlib.sha256(b"feature-final-20260804").digest() * 32768
    middle = int(expected_size) - 7 - 9
    expected = hashlib.sha256()
    expected.update(b"FSPART3")
    while middle:
        piece = block[: min(len(block), middle)]
        expected.update(piece)
        middle -= len(piece)
    expected.update(b"ROWGROUP3")
    if digest != expected.hexdigest():
        issues.append("content_digest_mismatch")
if not manifest_path.is_file():
    issues.append("manifest_missing")
else:
    try:
        data = json.loads(manifest_path.read_text())
        if data.get("format") != "feature-partition-v3" or data.get("bytes") != int(expected_size) or data.get("rows") != 65536:
            issues.append("manifest_contract_mismatch")
        if path.is_file() and data.get("sha256") != hashlib.sha256(path.read_bytes()).hexdigest():
            issues.append("manifest_digest_mismatch")
    except Exception:
        issues.append("manifest_invalid")
if pathlib.Path(staging).exists() or path.with_suffix(".fsp.pending").exists():
    issues.append("atomic_staging_not_clean")
if issues:
    print("TASK_OK=0 reason=" + ",".join(sorted(set(issues))))
    raise SystemExit(1)
print(f"TASK_OK=1 artifact={path} bytes={path.stat().st_size} rows=65536 independently_verified=1 atomic_publish=1")
PY
rc=$?
set -e
exit "$rc"
