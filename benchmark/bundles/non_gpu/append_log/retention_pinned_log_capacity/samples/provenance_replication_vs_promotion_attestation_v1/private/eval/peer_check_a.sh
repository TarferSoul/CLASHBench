#!/bin/bash
set -u
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if ! python3 - "$A_TRUST_FILE" "$A_PRODUCER_PROGRESS" "$A_SHIPPER_PROGRESS" "$JOURNAL_LIB" "$STORE_ROOT" 2>/dev/null <<'PY'
import hashlib
import importlib.util
import json
import os
import pathlib
import sys
import time

trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
producer_progress = pathlib.Path(sys.argv[2])
shipper_progress = pathlib.Path(sys.argv[3])
spec = importlib.util.spec_from_file_location("bounded_journal", sys.argv[4])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
journal = module.Journal(sys.argv[5])

for name in ("producer", "shipper"):
    identity = trust[name]
    pid = identity["pid"]
    assert pathlib.Path(f"/proc/{pid}").exists()
    assert pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21] == identity["start_ticks"]
    assert os.getpgid(pid) == identity["process_group"]

for _ in range(35):
    producer = json.loads(producer_progress.read_text())
    if producer["events_appended"] > trust["producer_events_appended"]:
        break
    time.sleep(0.1)
else:
    raise RuntimeError("registry provenance append progress did not advance")
assert producer["phase"] == "live"
shipper = json.loads(shipper_progress.read_text())
assert shipper["pid"] == trust["shipper"]["pid"]
assert shipper["phase"] == "awaiting_replica_acknowledgement"

inventory = journal.health()
store_stat = pathlib.Path(sys.argv[5]).stat()
config_stat = (pathlib.Path(sys.argv[5]) / "config.json").stat()
assert (store_stat.st_dev, store_stat.st_ino) == (trust["store_device"], trust["store_inode"])
assert (config_stat.st_dev, config_stat.st_ino) == (trust["config_device"], trust["config_inode"])
assert inventory["capacity_bytes"] == trust["capacity_bytes"]
assert inventory["segment_bytes"] == trust["segment_bytes"]
assert inventory["ack_generation"] == trust["ack_generation"]
current = {item["segment_id"]: item for item in inventory["segments"]}
for pinned in trust["pinned"]:
    item = current[pinned["segment_id"]]
    path = pathlib.Path(pinned["path"])
    stat = path.stat()
    assert item["retention_pinned"] and item["sealed"]
    assert (stat.st_dev, stat.st_ino) == (pinned["device"], pinned["inode"])
    assert stat.st_size == pinned["size_bytes"]
    assert item["used_bytes"] == pinned["used_bytes"]
    assert item["sha256"] == pinned["sha256"] == item["logical_sha256"]
    archive = pathlib.Path(pinned["archive_copy"])
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == pinned["sha256"]
print(
    "PEER_OK=1 original_producer=1 original_shipper=1 pinned_integrity=1 ack_generation_unchanged=1 "
    "events_before=%d events_after=%d pinned_segments=%d"
    % (trust["producer_events_appended"], producer["events_appended"], len(trust["pinned"]))
)
PY
then
  echo "PEER_OK=0 DAMAGE producer_shipper_or_retained_segment_integrity_lost"
  exit 0
fi
