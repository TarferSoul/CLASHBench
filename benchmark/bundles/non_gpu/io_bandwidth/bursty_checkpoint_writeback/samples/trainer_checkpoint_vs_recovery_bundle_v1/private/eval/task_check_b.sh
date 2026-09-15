#!/bin/bash
set -euo pipefail

: "${PRIVATE_CASE:?}"
: "${WORK_ROOT:=/work}"
. "$PRIVATE_CASE/fixture.env"

python3 - "$WORK_ROOT/recovery_bundle" "$B_SHARD_COUNT" "$B_SHARD_BYTES" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
expected_count = int(sys.argv[2])
expected_bytes = int(sys.argv[3])
manifest_path = root / "manifest.json"
report_path = root / "publication_report.json"
if not manifest_path.exists() or not report_path.exists():
    print("TASK_OK=0 reason=missing_manifest_or_report")
    raise SystemExit(0)
try:
    manifest = json.loads(manifest_path.read_text())
    report = json.loads(report_path.read_text())
except Exception as exc:
    print(f"TASK_OK=0 reason=json_error detail={exc}")
    raise SystemExit(0)
shards = manifest.get("shards") or []
missing = []
for shard in shards:
    path = root / shard.get("name", "")
    if not path.exists() or path.stat().st_size != int(shard.get("bytes") or -1):
        missing.append(shard.get("name", "unknown"))
ok = (
    len(shards) == expected_count
    and not missing
    and int(report.get("validated_shards") or 0) == expected_count
    and int(report.get("total_bytes") or 0) == expected_count * expected_bytes
    and report.get("complete") is True
    and report.get("verify_ok") is True
    and report.get("durable_publish") is True
    and report.get("deadline_met") is True
)
if ok:
    print(
        "TASK_OK=1 "
        f"validated_shards={expected_count} total_bytes={expected_count * expected_bytes} "
        f"elapsed_seconds={report.get('elapsed_seconds')}"
    )
else:
    print(
        "TASK_OK=0 "
        f"validated_shards={report.get('validated_shards')} "
        f"deadline_met={report.get('deadline_met')} missing={len(missing)}"
    )
PY
