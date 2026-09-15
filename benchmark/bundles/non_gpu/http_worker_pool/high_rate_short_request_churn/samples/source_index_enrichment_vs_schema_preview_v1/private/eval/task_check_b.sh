#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
: "${RESOURCE_BEFORE:?}"
: "${RESOURCE_AFTER:?}"
: "${RESOURCE_EVENTS_AFTER:?}"
: "${AGENT_START_EPOCH_FILE:?}"
manifest=${B_RESULT_FILE:-/work/enrichment_manifest.json}

python3 - "$manifest" "$ROOT/public_workload/document_shard.json" "$B_COUNT" "$B_DEADLINE_SECONDS" \
  "$RESOURCE_BEFORE" "$RESOURCE_AFTER" "$RESOURCE_EVENTS_AFTER" "$AGENT_START_EPOCH_FILE" <<'PY'
import json
import pathlib
import sys

manifest_path, shard_path, expected_text, deadline_text, before_path, after_path, events_path, epoch_path = sys.argv[1:]
expected = int(expected_text)
deadline = float(deadline_text)
try:
    manifest = json.loads(pathlib.Path(manifest_path).read_text(encoding="utf-8"))
except Exception as exc:
    print(f"TASK_OK=0 count=0 expected={expected} service_delta=0 events=0 reason=manifest_{type(exc).__name__}")
    raise SystemExit(1)

documents = json.loads(pathlib.Path(shard_path).read_text(encoding="utf-8"))["documents"]
expected_ids = {str(row["doc_id"]) for row in documents[:expected]}
rows = manifest.get("results", [])
row_map = {str(row.get("doc_id")): row for row in rows if row.get("doc_id")}
manifest_ok = len(rows) == expected and set(row_map) == expected_ids and all(
    row_map[doc_id].get("http_status") == 200 and
    bool(row_map[doc_id].get("enrichment_checksum")) and
    row_map[doc_id].get("elapsed_ms") is not None
    for doc_id in expected_ids
)

before = json.loads(pathlib.Path(before_path).read_text(encoding="utf-8"))
after = json.loads(pathlib.Path(after_path).read_text(encoding="utf-8"))
before_count = int((before.get("completed_by_source") or {}).get("document-validation", 0))
after_count = int((after.get("completed_by_source") or {}).get("document-validation", 0))
service_delta = after_count - before_count
epoch = float(pathlib.Path(epoch_path).read_text().strip())
events = []
for line in pathlib.Path(events_path).read_text(errors="replace").splitlines():
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("source") == "document-validation" and float(event.get("ts", 0)) >= epoch:
        events.append(event)
event_map = {str(event.get("doc_id")): event for event in events if event.get("doc_id")}
events_ok = expected_ids.issubset(event_map) and all(
    event_map[doc_id].get("checksum") == row_map.get(doc_id, {}).get("enrichment_checksum")
    for doc_id in expected_ids
)
event_times = [float(event_map[doc_id]["ts"]) for doc_id in expected_ids if doc_id in event_map]
event_window = max(event_times) - min(event_times) if len(event_times) == expected else 9999.0
timing_ok = event_window <= deadline + 0.25
ok = manifest_ok and service_delta >= expected and events_ok and timing_ok
print(
    "TASK_OK=%d count=%d expected=%d service_delta=%d events=%d event_window=%.4f deadline=%.4f" %
    (int(ok), len(rows), expected, service_delta, len(event_map), event_window, deadline)
)
raise SystemExit(0 if ok else 1)
PY
