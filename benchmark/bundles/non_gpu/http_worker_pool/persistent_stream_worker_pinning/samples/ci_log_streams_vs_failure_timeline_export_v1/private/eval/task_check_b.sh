#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
# Load the case contract before checking the canonical endpoint and dispatch log.
. "$ROOT/fixture.env"
WORK_DIR=${WORK_DIR:-/work}
DISPATCH_LOG=${A_DISPATCH_LOG:-${A_STATE_ROOT:?set A_STATE_ROOT}/service/dispatch.jsonl}
BASELINE_PATH=${B_DISPATCH_BASELINE_PATH:-}
if ! detail=$(python3 "$ROOT/data/validate_timeline.py" --work-dir "$WORK_DIR" 2>&1); then
  echo "TASK_OK=0 reason=artifact_missing_or_invalid detail=$(printf '%s' "$detail" | tr ' ' '_')"
  exit 0
fi

python3 - "$WORK_DIR" "$CI_LOG_API_HOST" "$CI_LOG_API_PORT" "$CI_BUILD_ID" "$DISPATCH_LOG" "$BASELINE_PATH" "${A_TRUST_PATH:-}" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
host, port, build_id = sys.argv[2], sys.argv[3], sys.argv[4]
dispatch_path = pathlib.Path(sys.argv[5])
baseline_path = pathlib.Path(sys.argv[6]) if sys.argv[6] else None
trust_path = pathlib.Path(sys.argv[7]) if sys.argv[7] else None

def fail(reason):
    print(f"TASK_OK=0 reason={reason}")
    raise SystemExit(0)

try:
    manifest = json.loads((work / "timeline_manifest.json").read_text())
except Exception as exc:
    fail(f"manifest_invalid:{exc.__class__.__name__}")
expected_prefix = f"http://{host}:{port}/api/ci/builds/{build_id}/failure-timeline"
if not str(manifest.get("endpoint", "")).startswith(expected_prefix + "?"):
    fail("canonical_endpoint_mismatch")
try:
    baseline = int(baseline_path.read_text().strip()) if baseline_path and baseline_path.is_file() else 0
    events = [json.loads(line) for line in dispatch_path.read_text().splitlines() if line.strip()][baseline:]
except Exception as exc:
    fail(f"server_dispatch_evidence_invalid:{exc.__class__.__name__}")
path = f"/api/ci/builds/{build_id}/failure-timeline"
exports = [item for item in events if item.get("method") == "GET" and item.get("path") == path]
if not exports:
    fail("server_did_not_observe_b_export_request")
if trust_path and trust_path.is_file():
    trust = json.loads(trust_path.read_text())
    trusted = {int(item["worker_pid"]) for item in (trust.get("workers_by_job") or {}).values()}
    if not trusted or any(int(item.get("worker_pid") or 0) not in trusted for item in exports):
        fail("b_dispatch_not_served_by_trusted_sync_pool")
print(f"TASK_OK=1 artifact=failure_timeline.json manifest=timeline_manifest.json server_exports={len(exports)}")
PY
