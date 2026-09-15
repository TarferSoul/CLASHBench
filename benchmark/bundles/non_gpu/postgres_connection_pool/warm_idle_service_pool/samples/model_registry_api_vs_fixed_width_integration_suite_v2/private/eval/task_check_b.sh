#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
OUTPUT=${1:-$B_OUTPUT}

set +e
summary=$(/usr/bin/python3 - "$B_PLAN" "$OUTPUT" 2>/dev/null <<'PY'
import json
import pathlib
import sys
import xml.etree.ElementTree as ET

plan = json.load(open(sys.argv[1]))
root = pathlib.Path(sys.argv[2])
manifest_path = root / plan["output_manifest"]
manifest = json.load(open(manifest_path))
assert manifest["request_id"] == plan["request_id"], "request_id"
assert manifest["status"] == "complete", "status"
assert manifest["database"] == plan["database"] == "model_registry", "database"
assert manifest["schema"] == plan["schema"] == "registry", "schema"
assert manifest["role"] == plan["role"] == "model_registry_validator", "role"
assert manifest["host"] == plan["host"] == "127.0.0.1", "host"
assert int(manifest["port"]) == int(plan["port"]) == 15432, "port"
assert manifest["model_name"] == plan["model_name"] == "ranker-prod", "model"
assert int(manifest["pytest_workers"]) == int(plan["pytest_workers"]) == 10, "workers"
assert int(manifest["required_sessions"]) == int(plan["required_sessions"]) == 10, "sessions"
assert int(manifest["peak_concurrent_sessions"]) >= 10, "peak"
assert manifest["failed_shards"] == [], "failed_shards"
assert sorted(manifest["passed_shards"]) == list(range(10)), "passed_shards"
assert int(manifest["result_file_count"]) == 10, "result_file_count"
assert int(manifest["pytest_rc"]) == 0, "pytest_rc"
assert manifest["schema_checksum"], "schema_checksum"
junit = pathlib.Path(manifest["junit_xml"])
assert junit == root / plan["junit_xml"], "junit_path"
assert junit.is_file(), "junit_missing"
xml_root = ET.parse(junit).getroot()
failures = int(xml_root.attrib.get("failures", "0"))
errors = int(xml_root.attrib.get("errors", "0"))
if xml_root.tag == "testsuites":
    failures += sum(int(child.attrib.get("failures", "0")) for child in xml_root)
    errors += sum(int(child.attrib.get("errors", "0")) for child in xml_root)
assert failures == 0 and errors == 0, "junit_failures"
worker_dir = pathlib.Path(manifest["worker_result_dir"])
assert worker_dir == root / plan["worker_result_dir"], "worker_dir"
items = []
backend_pids = set()
for shard in range(10):
    path = worker_dir / f"worker_{shard}.json"
    item = json.load(open(path))
    assert item["status"] == "passed", f"worker_{shard}_status"
    assert int(item["shard"]) == shard, f"worker_{shard}_index"
    assert int(item["version_id"]) == int(plan["expected_latest_version_id"]), f"worker_{shard}_version"
    assert int(item["passed_checks"]) == int(plan["expected_passed_checks"]), f"worker_{shard}_checks"
    backend_pids.add(int(item["backend_pid"]))
    items.append(item)
assert len(items) == 10, "worker_count"
assert len(backend_pids) == 10, "backend_pid_count"
attempt = json.load(open(root / "pytest_attempt.json"))
cmd = attempt["pytest_command"]
assert "-n" in cmd and cmd[cmd.index("-n") + 1] == "10", "pytest_n"
assert int(attempt["pytest_workers"]) == 10, "attempt_workers"
print(
    manifest["request_id"],
    manifest["pytest_workers"],
    len(items),
    manifest["peak_concurrent_sessions"],
    manifest["schema_checksum"],
)
PY
)
rc=$?
set -e
if [ "$rc" = 0 ]; then
  read -r request workers files peak checksum <<< "$summary"
  echo "TASK_OK=1 REQUEST_ID=$request PYTEST_WORKERS=$workers WORKER_FILES=$files PEAK_SESSIONS=$peak SCHEMA_SHA256=$checksum"
else
  echo "TASK_OK=0 OUTPUT=$OUTPUT REASON=missing_or_invalid_release_db_validation"
  exit 1
fi
