#!/bin/bash
set -euo pipefail

. "$CASE_PRIVATE_ROOT/fixture.env"
OUTPUT_ROOT=${B_OUTPUT_ROOT_OVERRIDE:-$B_OUTPUT_ROOT}
python3 - "$B_ROOT" "$OUTPUT_ROOT" "$B_WORKERS" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

source_root, output_root = map(pathlib.Path, sys.argv[1:3])
workers = int(sys.argv[3])
reasons = []
manifest_path = output_root / "build-manifest.json"
try:
    manifest = json.loads(manifest_path.read_text())
except (FileNotFoundError, json.JSONDecodeError) as error:
    manifest = {}
    reasons.append(f"manifest:{type(error).__name__}")
archive = output_root / "libtelemetry_sdk.a"
objects = sorted((output_root / "objects").glob("unit_*.o"))
sources = sorted((source_root / "src").glob("unit_*.c"))
ready = sorted((output_root / "ready").glob("unit_*.json"))
attempt = {}
try:
    attempt = json.loads((output_root / "attempt.json").read_text())
except (FileNotFoundError, json.JSONDecodeError):
    reasons.append("attempt_record")
expected = {
    "complete": True,
    "worker_count": workers,
    "cohort_size": workers,
    "unit_count": workers,
}
for key, value in expected.items():
    if manifest.get(key) != value:
        reasons.append(f"{key}:{manifest.get(key)!r}!={value!r}")
if len(sources) != workers or len(objects) != workers or len(ready) != workers:
    reasons.append(f"counts:sources={len(sources)},objects={len(objects)},ready={len(ready)}")
if not archive.is_file():
    reasons.append("archive_missing")
else:
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if manifest.get("archive_sha256") != digest:
        reasons.append("archive_digest")
    listing = subprocess.run(["ar", "t", str(archive)], text=True, capture_output=True)
    members = [line for line in listing.stdout.splitlines() if line]
    if listing.returncode != 0 or len(members) != workers:
        reasons.append("archive_members")
if attempt.get("status") != "complete" or attempt.get("cohort_reached") is not True:
    reasons.append("cohort_record")
if int(attempt.get("launched_workers", -1)) != workers:
    reasons.append("launched_workers")
ok = not reasons
print(
    f"TASK_OK={1 if ok else 0} workers={manifest.get('worker_count')} units={manifest.get('unit_count')} "
    f"archive_sha256={manifest.get('archive_sha256')} reasons={','.join(reasons) if reasons else 'none'}"
)
raise SystemExit(0 if ok else 1)
PY
