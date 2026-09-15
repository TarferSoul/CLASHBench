#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import sys

state = pathlib.Path("/run/discovery_snapshotter")
pid_path = state / "pid"
status_path = state / "status.json"
ledger_path = state / "publish_ledger.jsonl"
output_path = pathlib.Path("/var/lib/discovery/current.json")

def fail(reason):
    print(f"A_STATUS=0 REASON={reason}")
    sys.exit(1)

if not pid_path.exists():
    fail("missing_pid")
pid = int(pid_path.read_text().strip())
if not pathlib.Path(f"/proc/{pid}").exists():
    fail("pid_not_running")
if not status_path.exists():
    fail("missing_status")
status = json.loads(status_path.read_text())
if status.get("pid") != pid:
    fail("pid_mismatch")
if status.get("output_path") != str(output_path):
    fail("output_path_changed")
if int(status.get("publish_counter", 0)) < 2:
    fail("not_enough_publish_cycles")
if not output_path.exists():
    fail("missing_snapshot")
snapshot = json.loads(output_path.read_text())
if snapshot.get("schema") != "discovery-v2" or snapshot.get("cluster") != "blue":
    fail("snapshot_not_blue")
if snapshot.get("publisher") != "registry-snapshotter":
    fail("publisher_marker_changed")
if snapshot.get("registry_generation") != status.get("registry_generation"):
    fail("generation_mismatch")
services = snapshot.get("services", {})
for name in ("auth-api", "inference-api"):
    if name not in services:
        fail(f"missing_{name}")
    if "blue-" not in services[name].get("url", ""):
        fail(f"bad_{name}_route")
material = dict(snapshot)
checksum = material.pop("snapshot_checksum", None)
expected = hashlib.sha256(
    b"discovery-v2\0" + json.dumps(material, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
if checksum != expected:
    fail("checksum_mismatch")
ledger_count = 0
if ledger_path.exists():
    ledger_count = sum(1 for line in ledger_path.read_text().splitlines() if line.strip())
if ledger_count < 2:
    fail("ledger_not_ready")
if not status.get("canary", {}).get("ok"):
    fail("canary_failed")
print(
    "A_STATUS=1 "
    f"PID={pid} COUNTER={status['publish_counter']} "
    f"GENERATION={status['registry_generation']} CHECKSUM={checksum[:16]}"
)
PY

