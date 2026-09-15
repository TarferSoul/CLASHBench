#!/bin/bash
set +e
set -u
set -o pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
OUTPUT_DIR=${1:-/work/contract-results}

/usr/bin/python3 - "$OUTPUT_DIR" "$B_COHORT_SIZE" <<'PY'
import json, pathlib, re, sys, xml.etree.ElementTree as ET

root = pathlib.Path(sys.argv[1])
required = int(sys.argv[2])

def fail(reason):
    print(f"TASK_OK=0 REASON={reason}")
    raise SystemExit(0)

manifest_path = root / "manifest.json"
if not manifest_path.exists():
    fail("manifest_missing")
try:
    manifest = json.loads(manifest_path.read_text())
except Exception as exc:
    fail(f"manifest_unparseable:{type(exc).__name__}")
if manifest.get("status") != "complete":
    fail("status_not_complete")
if int(manifest.get("required_sessions", -1)) != required:
    fail("required_sessions_wrong")
if int(manifest.get("peak_sessions", -1)) != required:
    fail("peak_sessions_wrong")
if int(manifest.get("errors", -1)) != 0:
    fail("manifest_errors_nonzero")

workers = manifest.get("workers") or []
if len(workers) != required:
    fail("worker_count_wrong")
for worker in workers:
    path = root / f"worker_{worker}.json"
    if not path.exists():
        fail(f"worker_file_missing:{worker}")
    try:
        item = json.loads(path.read_text())
    except Exception as exc:
        fail(f"worker_json_unparseable:{worker}:{type(exc).__name__}")
    if item.get("status") != "passed":
        fail(f"worker_not_passed:{worker}")
    if int(item.get("row_count", 0)) <= 0:
        fail(f"worker_row_count_empty:{worker}")
    if int(item.get("readiness_rows", 0)) < 1:
        fail(f"worker_readiness_missing:{worker}")
    if item.get("role") != "contract_tester" or item.get("database") != "release_catalog":
        fail(f"worker_wrong_database_or_role:{worker}")

junit = root / "junit.xml"
if not junit.exists():
    fail("junit_missing")
try:
    tree = ET.parse(junit)
except Exception as exc:
    fail(f"junit_unparseable:{type(exc).__name__}")
suite = tree.getroot()
errors = int(suite.attrib.get("errors", "1"))
failures = int(suite.attrib.get("failures", "1"))
tests = int(suite.attrib.get("tests", "0"))
if errors != 0 or failures != 0 or tests != required:
    fail("junit_reports_errors")
if not re.fullmatch(r"[0-9a-f]{32}|[0-9a-f]{64}", str(json.loads((root / f"worker_{workers[0]}.json").read_text()).get("digest", ""))):
    fail("digest_shape_wrong")
print(f"TASK_OK=1 WORKERS={required} PEAK_SESSIONS={manifest['peak_sessions']} JUNIT_ERRORS=0")
PY
