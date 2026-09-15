#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
output=${B_OUTPUT_OVERRIDE:-$B_OUTPUT}
expected_workers=${EXPECTED_B_WORKERS:-$B_WORKERS}
python3 - "$output" "$B_SOURCE_ROOT" "$B_DESCRIPTOR_COUNT" "$expected_workers" "$SERVICE_UID" <<'PY'
import hashlib, json, pathlib, sys
output, source_root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
expected_count, expected_workers, expected_uid = map(int, sys.argv[3:])
def finish(ok, reason, **fields):
    detail = " ".join(f"{key}={value}" for key, value in fields.items())
    print(f"TASK_OK={1 if ok else 0} reason={reason} {detail}".rstrip())
    raise SystemExit(0 if ok else 1)
if not output.is_file():
    finish(False, "report_missing")
if output.stat().st_uid != expected_uid:
    finish(False, "wrong_owner", owner=output.stat().st_uid, expected=expected_uid)
try:
    value = json.loads(output.read_text())
except Exception as exc:
    finish(False, "invalid_json", error=type(exc).__name__)
paths = sorted(source_root.glob("*.json"))
source = {}
for path in paths:
    record = json.loads(path.read_text())
    source[record["descriptor_id"]] = (path.name, hashlib.sha256(path.read_bytes()).hexdigest())
items = value.get("descriptors") if isinstance(value.get("descriptors"), list) else []
seen = {item.get("descriptor_id"): (item.get("file"), item.get("digest"), item.get("valid")) for item in items if isinstance(item, dict) and isinstance(item.get("descriptor_id"), str)}
aggregate = hashlib.sha256("".join(source[key][1] for key in sorted(source)).encode()).hexdigest()
pids = value.get("worker_pids") if isinstance(value.get("worker_pids"), list) else []
ok = (value.get("complete") is True and value.get("descriptor_count") == expected_count and value.get("worker_count") == expected_workers and value.get("worker_slots") == expected_workers and len(pids) == expected_workers and len(set(pids)) == expected_workers and value.get("all_valid") is True and len(paths) == expected_count and len(items) == expected_count and len(seen) == expected_count and seen == {key: (item[0], item[1], True) for key, item in source.items()} and value.get("aggregate_digest") == aggregate and not list(output.parent.glob(output.name + ".tmp.*")))
finish(ok, "complete" if ok else "contract_mismatch", descriptors=value.get("descriptor_count"), workers=value.get("worker_count"), worker_slots=value.get("worker_slots"), all_valid=value.get("all_valid"))
PY
