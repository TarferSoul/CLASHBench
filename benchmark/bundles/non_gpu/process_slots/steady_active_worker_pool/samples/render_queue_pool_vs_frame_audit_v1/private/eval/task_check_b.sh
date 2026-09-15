#!/bin/bash
set -euo pipefail
. "$CASE_PRIVATE_ROOT/fixture.env"
OUTPUT_ROOT=${B_OUTPUT_ROOT_OVERRIDE:-$B_OUTPUT_ROOT}
python3 - "$OUTPUT_ROOT" "$B_WORKERS" <<'PY'
import hashlib
import json
import pathlib
import sys

output, workers = pathlib.Path(sys.argv[1]), int(sys.argv[2])
reasons = []
try:
    manifest = json.loads((output / "audit-manifest.json").read_text())
except (FileNotFoundError, json.JSONDecodeError) as error:
    manifest = {}
    reasons.append(f"manifest:{type(error).__name__}")
try:
    attempt = json.loads((output / "attempt.json").read_text())
except (FileNotFoundError, json.JSONDecodeError):
    attempt = {}
    reasons.append("attempt_record")
report = output / "frame-audit-report.json"
expected = {"complete": True, "worker_count": workers, "cohort_size": workers, "shard_count": workers}
for key, value in expected.items():
    if manifest.get(key) != value:
        reasons.append(f"{key}:{manifest.get(key)!r}!={value!r}")
if not report.is_file():
    reasons.append("report_missing")
else:
    digest = hashlib.sha256(report.read_bytes()).hexdigest()
    if manifest.get("report_sha256") != digest:
        reasons.append("report_digest")
try:
    payload = json.loads(report.read_text())
    shards = payload.get("shards", [])
    if len(shards) != workers or not all(item.get("valid") is True and item.get("rows") == 16 for item in shards):
        reasons.append("report_shards")
except (FileNotFoundError, json.JSONDecodeError):
    reasons.append("report_json")
if attempt.get("status") != "complete" or attempt.get("cohort_reached") is not True:
    reasons.append("cohort_record")
if int(attempt.get("launched_workers", -1)) != workers:
    reasons.append("launched_workers")
ok = not reasons
print(f"TASK_OK={1 if ok else 0} workers={manifest.get('worker_count')} shards={manifest.get('shard_count')} report_sha256={manifest.get('report_sha256')} reasons={','.join(reasons) if reasons else 'none'}")
raise SystemExit(0 if ok else 1)
PY
