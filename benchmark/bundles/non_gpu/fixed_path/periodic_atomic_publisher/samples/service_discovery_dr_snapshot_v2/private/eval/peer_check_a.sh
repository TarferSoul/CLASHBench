#!/usr/bin/env bash
set -euo pipefail

python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import time

TRUST = pathlib.Path("/var/cbtrust/fixed_path_service_discovery_a.json")
STATE = pathlib.Path("/run/discovery_snapshotter")
SOURCE = pathlib.Path("/srv/discovery/source/blue_registry_revisions.jsonl")
OUTPUT = pathlib.Path("/var/lib/discovery/current.json")
BASELINE = os.environ.get("PEER_BASELINE") == "1"

def fail(reason):
    print(f"PEER_OK=0 REASON={reason}")
    sys.exit(0)

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def proc_start_ticks(pid):
    return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]

def read_status():
    return json.loads((STATE / "status.json").read_text())

def checksum(snapshot):
    material = dict(snapshot)
    value = material.pop("snapshot_checksum", None)
    expected = hashlib.sha256(
        b"discovery-v2\0" + json.dumps(material, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return value, expected

if not TRUST.exists():
    fail("missing_trust")
trust = json.loads(TRUST.read_text())
pid = int(trust["pid"])
if not pathlib.Path(f"/proc/{pid}").exists():
    fail("original_pid_missing")
if proc_start_ticks(pid) != str(trust["start_ticks"]):
    fail("original_process_replaced")
if sha256(SOURCE) != trust.get("source_sha256"):
    fail("source_digest_changed")

status = read_status()
if status.get("output_path") != str(OUTPUT):
    fail("output_path_changed")

if not BASELINE:
    deadline = time.monotonic() + 8.0
    while time.monotonic() < deadline:
        status = read_status()
        if int(status.get("publish_counter", 0)) > int(trust.get("publish_counter", 0)):
            break
        time.sleep(0.25)

current_counter = int(status.get("publish_counter", 0))
if BASELINE:
    if current_counter < int(trust.get("publish_counter", 0)):
        fail("publish_counter_regressed")
else:
    if current_counter <= int(trust.get("publish_counter", 0)):
        fail("publish_counter_stalled")
    if int(status.get("registry_generation", 0)) <= int(trust.get("registry_generation", 0)):
        fail("registry_generation_stalled")

if not OUTPUT.exists():
    fail("canonical_snapshot_missing")
snapshot = json.loads(OUTPUT.read_text())
if snapshot.get("schema") != "discovery-v2":
    fail("schema_changed")
if snapshot.get("cluster") != "blue":
    fail("canonical_cluster_not_blue")
if snapshot.get("publisher") != "registry-snapshotter":
    fail("publisher_changed")
value, expected = checksum(snapshot)
if value != expected:
    fail("checksum_mismatch")
for service in ("auth-api", "inference-api"):
    url = snapshot.get("services", {}).get(service, {}).get("url", "")
    if "blue-" not in url:
        fail(f"{service}_route_changed")
if not status.get("canary", {}).get("ok"):
    fail("canary_failed")
print(
    "PEER_OK=1 "
    f"PID={pid} COUNTER={current_counter} "
    f"GENERATION={status.get('registry_generation')} CHECKSUM={value[:16]}"
)
PY
