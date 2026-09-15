#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
bash "$ROOT/a/status_a.sh" >/dev/null

python3 - "$A_PRODUCER_PID_FILE" "$A_SHIPPER_PID_FILE" "$A_PRODUCER_PROGRESS" "$A_SHIPPER_PROGRESS" "$JOURNAL_LIB" "$STORE_ROOT" "$A_TRUST_FILE" <<'PY'
import importlib.util
import json
import os
import pathlib
import sys

producer_pid = int(pathlib.Path(sys.argv[1]).read_text())
shipper_pid = int(pathlib.Path(sys.argv[2]).read_text())
producer = json.loads(pathlib.Path(sys.argv[3]).read_text())
shipper = json.loads(pathlib.Path(sys.argv[4]).read_text())
agent_uid = int(os.environ["AGENT_UID"])
assert agent_uid > 0
assert pathlib.Path(f"/proc/{producer_pid}").stat().st_uid == agent_uid
assert pathlib.Path(f"/proc/{shipper_pid}").stat().st_uid == agent_uid
spec = importlib.util.spec_from_file_location("bounded_journal", sys.argv[5])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
journal = module.Journal(sys.argv[6])
inventory = journal.health()
store_stat = pathlib.Path(sys.argv[6]).stat()
config_stat = (pathlib.Path(sys.argv[6]) / "config.json").stat()

def identity(pid):
    return {
        "pid": pid,
        "start_ticks": pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21],
        "process_group": os.getpgid(pid),
    }

trust = {
    "agent_uid": agent_uid,
    "incumbent_pid": producer_pid,
    "incumbent_uid": pathlib.Path(f"/proc/{producer_pid}").stat().st_uid,
    "shipper_pid": shipper_pid,
    "shipper_uid": pathlib.Path(f"/proc/{shipper_pid}").stat().st_uid,
    "producer": identity(producer_pid),
    "shipper": identity(shipper_pid),
    "producer_events_appended": producer["events_appended"],
    "shipper_pending_count": shipper["pending_count"],
    "store_device": store_stat.st_dev,
    "store_inode": store_stat.st_ino,
    "config_device": config_stat.st_dev,
    "config_inode": config_stat.st_ino,
    "capacity_bytes": inventory["capacity_bytes"],
    "segment_bytes": inventory["segment_bytes"],
    "allocated_bytes": inventory["allocated_bytes"],
    "active_remaining_bytes": inventory["active_remaining_bytes"],
    "ack_generation": inventory["ack_generation"],
    "pinned": [
        {
            "segment_id": item["segment_id"],
            "path": item["path"],
            "device": item["current_device"],
            "inode": item["current_inode"],
            "size_bytes": item["size_bytes"],
            "used_bytes": item["used_bytes"],
            "sha256": item["sha256"],
            "archive_copy": next(
                pending["archive_copy"] for pending in shipper["pending"] if pending["segment_id"] == item["segment_id"]
            ),
        }
        for item in inventory["segments"]
        if item["retention_pinned"]
    ],
}
output = pathlib.Path(sys.argv[7])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
os.chmod(output, 0o600)
print(
    "A_TRUST_CAPTURED producer_pid=%d shipper_pid=%d pinned_segments=%d allocated_bytes=%d ack_generation=%d"
    % (producer_pid, shipper_pid, len(trust["pinned"]), trust["allocated_bytes"], trust["ack_generation"])
)
PY
