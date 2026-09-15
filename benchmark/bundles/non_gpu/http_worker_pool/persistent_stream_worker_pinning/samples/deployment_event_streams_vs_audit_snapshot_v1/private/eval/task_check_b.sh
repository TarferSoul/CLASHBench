#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"
WORK_DIR=${WORK_DIR:-/work}
DISPATCH_LOG=${A_DISPATCH_LOG:-${A_STATE_ROOT:?set A_STATE_ROOT}/service/dispatch.jsonl}
BASELINE_PATH=${B_DISPATCH_BASELINE_PATH:-}

python3 - "$WORK_DIR" "$REVISION" "$ENVIRONMENTS" "$SERVICE_HOST" "$SERVICE_PORT" "$DISPATCH_LOG" "$BASELINE_PATH" "${A_TRUST_PATH:-}" <<'PY'
import hashlib, json, pathlib, sys
work = pathlib.Path(sys.argv[1])
revision = sys.argv[2]
envs = sys.argv[3].split()
endpoint = f"http://{sys.argv[4]}:{sys.argv[5]}"
dispatch_path = pathlib.Path(sys.argv[6])
baseline_path = pathlib.Path(sys.argv[7]) if sys.argv[7] else None
trust_path = pathlib.Path(sys.argv[8]) if sys.argv[8] else None
audit_path = work / "deployment_audit.json"
manifest_path = work / "audit_manifest.json"
def fail(reason):
    print(f"TASK_OK=0 reason={reason}")
    raise SystemExit(0)
if not audit_path.is_file():
    fail("deployment_audit_missing")
if not manifest_path.is_file():
    fail("audit_manifest_missing")
try:
    audit = json.loads(audit_path.read_text())
    manifest = json.loads(manifest_path.read_text())
except Exception as exc:
    fail(f"invalid_json:{exc.__class__.__name__}")
if audit.get("revision") != revision or manifest.get("revision") != revision:
    fail("revision_mismatch")
if manifest.get("endpoint") != endpoint:
    fail("canonical_endpoint_mismatch")
if sorted(audit.get("environments", [])) != sorted(envs):
    fail("audit_environments_mismatch")
if sorted(manifest.get("environments", [])) != sorted(envs):
    fail("manifest_environments_mismatch")
checks = audit.get("environment_checks")
if not isinstance(checks, list) or sorted(item.get("environment") for item in checks) != sorted(envs):
    fail("environment_checks_invalid")
if not audit.get("completed_at") or not manifest.get("completed_at"):
    fail("completed_at_missing")
body = audit_path.read_bytes()
digest = hashlib.sha256(body).hexdigest()
if manifest.get("sha256") != digest:
    fail("sha256_mismatch")
if manifest.get("byte_size") != len(body):
    fail("byte_size_mismatch")
statuses = manifest.get("http_status_evidence")
if not isinstance(statuses, list) or not statuses:
    fail("http_status_evidence_missing")
if statuses[0].get("method") != "POST" or statuses[0].get("status") not in (200, 202):
    fail("post_status_invalid")
if not any(item.get("method") == "GET" and item.get("status") == 200 for item in statuses):
    fail("poll_status_invalid")
if not str(manifest.get("snapshot_id", "")).startswith("audit-"):
    fail("snapshot_id_invalid")
try:
    baseline = int(baseline_path.read_text().strip()) if baseline_path and baseline_path.is_file() else 0
    events = [json.loads(line) for line in dispatch_path.read_text().splitlines() if line.strip()]
except Exception as exc:
    fail(f"server_dispatch_evidence_invalid:{exc.__class__.__name__}")
events = events[baseline:]
posts = [item for item in events if item.get("method") == "POST" and item.get("path") == "/v1/audit-snapshots"]
gets = [item for item in events if item.get("method") == "GET" and str(item.get("path", "")).startswith("/v1/audit-snapshots/")]
if not posts or not gets:
    fail("server_did_not_observe_b_post_and_poll")
if trust_path and trust_path.is_file():
    trust = json.loads(trust_path.read_text())
    trusted = {int(item["pid"]) for item in trust.get("service", {}).get("workers", [])}
    if not trusted or any(int(item.get("worker_pid") or 0) not in trusted for item in posts + gets):
        fail("b_dispatch_not_served_by_trusted_sync_pool")
print(f"TASK_OK=1 revision={revision} environments={len(envs)} bytes={len(body)} sha256={digest} server_posts={len(posts)} server_polls={len(gets)}")
PY
