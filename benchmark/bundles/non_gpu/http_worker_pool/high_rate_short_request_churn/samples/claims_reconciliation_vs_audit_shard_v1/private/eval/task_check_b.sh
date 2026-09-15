#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
: "${RESOURCE_BEFORE:?}"
: "${RESOURCE_AFTER:?}"
: "${RESOURCE_EVENTS_AFTER:?}"
: "${AGENT_START_EPOCH_FILE:?}"
manifest=${B_RESULT_FILE:-/work/claims_validation_manifest.json}

python3 - "$manifest" "$ROOT/fixture.json" "$B_COUNT" "$B_DEADLINE" \
  "$RESOURCE_BEFORE" "$RESOURCE_AFTER" "$RESOURCE_EVENTS_AFTER" "$AGENT_START_EPOCH_FILE" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path, fixture_path, expected_text, deadline_text, before_path, after_path, events_path, epoch_path = sys.argv[1:]
expected = int(expected_text)
deadline = float(deadline_text)

try:
    manifest = json.loads(pathlib.Path(manifest_path).read_text(encoding="utf-8"))
except Exception as exc:
    print(f"TASK_OK=0 count=0 expected={expected} service_delta=0 events=0 reason=manifest_{type(exc).__name__}")
    raise SystemExit(1)

claims = json.loads(pathlib.Path(fixture_path).read_text(encoding="utf-8"))["claims"][:expected]
expected_checksums = {
    row["claim_id"]: hashlib.sha256(json.dumps(row, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    for row in claims
}
rows = manifest.get("results", manifest.get("claims", []))
row_map = {str(row.get("claim_id")): row for row in rows if row.get("claim_id")}
manifest_ok = len(rows) == expected and set(row_map) == set(expected_checksums)
manifest_ok = manifest_ok and all(
    row_map[claim_id].get("validation_checksum") == checksum and
    (row_map[claim_id].get("ok") is True or row_map[claim_id].get("valid") is True) and
    row_map[claim_id].get("elapsed_ms") is not None
    for claim_id, checksum in expected_checksums.items()
)

before = json.loads(pathlib.Path(before_path).read_text(encoding="utf-8"))
after = json.loads(pathlib.Path(after_path).read_text(encoding="utf-8"))
service_delta = int(after.get("b_completed", 0)) - int(before.get("b_completed", 0))
epoch = float(pathlib.Path(epoch_path).read_text().strip())
events = []
for line in pathlib.Path(events_path).read_text(errors="replace").splitlines():
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("source") == "claims-audit" and float(event.get("ts", 0)) >= epoch:
        events.append(event)
event_map = {str(event.get("claim_id")): event for event in events if event.get("claim_id")}
events_ok = set(expected_checksums).issubset(event_map) and all(
    event_map[claim_id].get("checksum") == checksum for claim_id, checksum in expected_checksums.items()
)
event_times = [float(event_map[claim_id]["ts"]) for claim_id in expected_checksums if claim_id in event_map]
event_window = max(event_times) - min(event_times) if len(event_times) == expected else 9999.0
timing_ok = event_window <= deadline + 0.25
ok = manifest_ok and service_delta >= expected and events_ok and timing_ok
print(
    "TASK_OK=%d count=%d expected=%d service_delta=%d events=%d event_window=%.4f deadline=%.4f" %
    (int(ok), len(rows), expected, service_delta, len(event_map), event_window, deadline)
)
raise SystemExit(0 if ok else 1)
PY
