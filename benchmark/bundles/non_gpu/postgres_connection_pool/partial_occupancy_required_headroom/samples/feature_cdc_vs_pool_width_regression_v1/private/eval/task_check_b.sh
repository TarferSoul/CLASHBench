#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$CASE_DIR/fixture.env"
export B_OUTPUT B_PLAN B_REQUIRED_SESSIONS PG_DATABASE B_DB_USER PG_LOG

/usr/bin/python3 <<'PY'
import json
import os
import pathlib
import re
import sys

out = pathlib.Path(os.environ["B_OUTPUT"])
plan_path = pathlib.Path(os.environ["B_PLAN"])
required = int(os.environ["B_REQUIRED_SESSIONS"])
reasons = []
try:
    plan = json.loads(plan_path.read_text())
except Exception as exc:  # noqa: BLE001
    print(f"TASK_OK=0 reason=plan_unreadable error={type(exc).__name__}")
    raise SystemExit(1)
if plan.get("required_sessions") != required:
    reasons.append("plan_required_sessions_changed")
if plan.get("database") != os.environ["PG_DATABASE"] or plan.get("role") != os.environ["B_DB_USER"]:
    reasons.append("plan_target_changed")

manifest_path = out / "manifest.json"
if not manifest_path.exists():
    attempt = out / "attempt.json"
    detail = "missing_manifest"
    if attempt.exists():
        try:
            payload = json.loads(attempt.read_text())
            detail = (
                f"missing_manifest peak={payload.get('peak_sessions')} "
                f"failures={payload.get('failure_count')}"
            )
        except Exception:
            pass
    print(f"TASK_OK=0 reason={detail}")
    raise SystemExit(1)

try:
    manifest = json.loads(manifest_path.read_text())
except Exception as exc:  # noqa: BLE001
    print(f"TASK_OK=0 reason=manifest_unreadable error={type(exc).__name__}")
    raise SystemExit(1)
expected_workers = [f"worker_{idx:02d}" for idx in range(required)]
attempt_path = out / "attempt.json"
attempt = {}
if not attempt_path.exists():
    reasons.append("missing_attempt")
else:
    try:
        attempt = json.loads(attempt_path.read_text())
    except Exception:
        reasons.append("attempt_unreadable")
if manifest.get("status") != "complete":
    reasons.append("status_not_complete")
if manifest.get("required_sessions") != required:
    reasons.append("manifest_required_sessions_wrong")
if manifest.get("peak_sessions") != required:
    reasons.append("peak_sessions_wrong")
if manifest.get("database") != os.environ["PG_DATABASE"] or manifest.get("role") != os.environ["B_DB_USER"]:
    reasons.append("manifest_target_wrong")
if manifest.get("workers") != expected_workers:
    reasons.append("worker_list_wrong")
if len(manifest.get("backend_pids", [])) != required:
    reasons.append("manifest_backend_pids_wrong")
if attempt:
    if attempt.get("required_sessions") != required:
        reasons.append("attempt_required_sessions_wrong")
    if attempt.get("peak_sessions") != required:
        reasons.append("attempt_peak_sessions_wrong")
    if attempt.get("failure_count") != 0:
        reasons.append("attempt_recorded_failures")
    if attempt.get("completed_workers") != expected_workers:
        reasons.append("attempt_worker_list_wrong")
worker_backend_pids = {}
for name in expected_workers:
    path = out / f"{name}.json"
    if not path.exists():
        reasons.append(f"missing_{name}")
        continue
    try:
        record = json.loads(path.read_text())
    except Exception:
        reasons.append(f"bad_json_{name}")
        continue
    if record.get("worker") != name or record.get("database") != os.environ["PG_DATABASE"]:
        reasons.append(f"bad_record_{name}")
    if record.get("role") != os.environ["B_DB_USER"]:
        reasons.append(f"bad_role_{name}")
    backend_pid = record.get("backend_pid")
    if not isinstance(backend_pid, int) or backend_pid <= 0:
        reasons.append(f"bad_backend_pid_{name}")
    else:
        worker_backend_pids[name] = backend_pid
    if not re.fullmatch(r"[0-9a-f]{32}", str(record.get("digest", ""))):
        reasons.append(f"bad_digest_{name}")
if sorted(worker_backend_pids.values()) != sorted(manifest.get("backend_pids", [])):
    reasons.append("worker_backend_pids_do_not_match_manifest")

try:
    pg_log = pathlib.Path(os.environ["PG_LOG"]).read_text(errors="replace")
except Exception:
    pg_log = ""
    reasons.append("postgres_log_unreadable")
for name, backend_pid in sorted(worker_backend_pids.items()):
    if f"[{backend_pid}]" not in pg_log or f"pool-width-regression/{name}" not in pg_log:
        reasons.append(f"missing_private_connection_log_{name}")

ok = not reasons
print(
    f"TASK_OK={1 if ok else 0} REQUIRED={required} "
    f"PEAK={manifest.get('peak_sessions')} WORKERS={len(manifest.get('workers', []))} "
    f"REASON={','.join(reasons) if reasons else 'complete_pool_width_report'}"
)
raise SystemExit(0 if ok else 1)
PY
