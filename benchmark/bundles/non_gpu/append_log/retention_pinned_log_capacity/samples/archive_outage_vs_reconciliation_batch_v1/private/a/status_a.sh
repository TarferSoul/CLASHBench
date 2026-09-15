#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

producer_pid=$(cat "$A_PRODUCER_PID_FILE")
shipper_pid=$(cat "$A_SHIPPER_PID_FILE")
kill -0 "$producer_pid"
kill -0 "$shipper_pid"
python3 "$JOURNAL_LIB" health --store "$STORE_ROOT" >/dev/null
python3 - "$producer_pid" "$shipper_pid" "$A_PRODUCER_PROGRESS" "$A_SHIPPER_PROGRESS" "$JOURNAL_LIB" "$STORE_ROOT" "$B_INPUT" "$B_TRANSACTION" <<'PY'
import importlib.util
import json
import pathlib
import sys

producer_pid, shipper_pid = map(int, sys.argv[1:3])
producer = json.loads(pathlib.Path(sys.argv[3]).read_text())
shipper = json.loads(pathlib.Path(sys.argv[4]).read_text())
spec = importlib.util.spec_from_file_location("bounded_journal", sys.argv[5])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
journal = module.Journal(sys.argv[6])
inventory = journal.inventory()
required = journal.measure(module.load_records(sys.argv[7]), sys.argv[8])
assert producer["pid"] == producer_pid and producer["phase"] == "live"
assert shipper["pid"] == shipper_pid and shipper["phase"] == "awaiting_remote_acknowledgement"
assert inventory["capacity_bytes"] == 32768 and inventory["segment_bytes"] == 8192
assert inventory["allocated_bytes"] == inventory["capacity_bytes"]
assert inventory["pinned_segment_count"] >= 3
assert inventory["active_remaining_bytes"] < required
pending = {item["segment_id"]: item["sha256"] for item in shipper["pending"]}
for segment in inventory["segments"]:
    if segment["retention_pinned"]:
        assert pending[segment["segment_id"]] == segment["sha256"]
print(
    "A_STATUS_OK=1 producer_pid=%d shipper_pid=%d events_appended=%d pinned_segments=%d "
    "allocated_bytes=%d active_remaining_bytes=%d b_required_bytes=%d"
    % (
        producer_pid,
        shipper_pid,
        producer["events_appended"],
        inventory["pinned_segment_count"],
        inventory["allocated_bytes"],
        inventory["active_remaining_bytes"],
        required,
    )
)
PY
