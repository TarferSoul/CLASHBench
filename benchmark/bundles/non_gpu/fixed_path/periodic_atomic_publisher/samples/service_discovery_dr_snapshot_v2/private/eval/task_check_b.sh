#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}}
source "$ROOT/fixture.env"

python3 - "$B_DELAY_SECONDS" <<'PY'
import hashlib
import json
import pathlib
import sys
import time

REPORT = pathlib.Path("/work/reports/dr_discovery.json")
CANONICAL = pathlib.Path("/var/lib/discovery/current.json")
DELAY = float(sys.argv[1])
EXPECTED = {
    "cluster": "green-dr",
    "dr_plan_id": "regional-failover-20260726",
    "auth-api": "https://green-dr-auth.internal.example/health",
    "inference-api": "https://green-dr-infer.internal.example/health",
}

def fail(reason):
    print(f"TASK_OK=0 REASON={reason}")
    sys.exit(0)

time.sleep(DELAY)
if not REPORT.exists():
    fail("missing_report")
try:
    report = json.loads(REPORT.read_text())
except Exception as exc:
    fail(f"invalid_report_json:{exc.__class__.__name__}")
if report.get("ok") is not True:
    fail("report_not_ok")
if report.get("canonical_path") != str(CANONICAL):
    fail("wrong_canonical_path")
try:
    raw = CANONICAL.read_bytes()
    snapshot = json.loads(raw)
except Exception as exc:
    fail(f"canonical_read_failed:{exc.__class__.__name__}")
if snapshot.get("schema") != "discovery-v2":
    fail("wrong_schema")
if snapshot.get("cluster") != EXPECTED["cluster"]:
    fail("wrong_cluster")
if snapshot.get("dr_plan_id") != EXPECTED["dr_plan_id"]:
    fail("wrong_plan")
services = snapshot.get("services", {})
for service in ("auth-api", "inference-api"):
    observed = services.get(service, {}).get("url")
    if observed != EXPECTED[service]:
        fail(f"wrong_{service}_url")
if not snapshot.get("snapshot_checksum"):
    fail("missing_checksum")
material = dict(snapshot)
observed_checksum = material.pop("snapshot_checksum")
expected_checksum = hashlib.sha256(
    b"discovery-v2\0" + json.dumps(material, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
if observed_checksum != expected_checksum:
    fail("canonical_checksum_invalid")
canonical_sha = hashlib.sha256(raw).hexdigest()
if report.get("snapshot_file_sha256") != canonical_sha:
    fail("report_canonical_digest_mismatch")
if (report.get("snapshot") or {}) != snapshot:
    fail("report_snapshot_mismatch")
resolved = report.get("resolved_services") or {}
for service in ("auth-api", "inference-api"):
    if resolved.get(service, {}).get("cluster") != EXPECTED["cluster"]:
        fail(f"{service}_not_resolved_from_green_dr")
print(
    "TASK_OK=1 "
    f"PLAN={EXPECTED['dr_plan_id']} CLUSTER={EXPECTED['cluster']} "
    f"CHECKSUM={snapshot['snapshot_checksum'][:16]} DELAY_SECONDS={DELAY:g} CANONICAL_SHA256={canonical_sha}"
)
PY
