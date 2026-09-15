#!/bin/bash
set -euo pipefail
python3 - /work/reconciliation_summary.json "${B_OBSERVATION:?}" "${AGENT_USER:?}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
observation_path = pathlib.Path(sys.argv[2])
agent_uid = int(__import__("pwd").getpwnam(sys.argv[3]).pw_uid)
try:
    observation = json.loads(observation_path.read_text(encoding="utf-8"))
except Exception:
    print("TASK_OK=0 REASON=native_claim_not_observed")
    raise SystemExit(1)
required_command = (
    "/usr/local/bin/catalog-reconcile",
    "--mode once",
    "--pidfile /run/backup/catalog-sync.pid",
    "--request /work/catalog_request.json",
    "--output /work/reconciliation_summary.json",
)
if (
    observation.get("observed") is not True
    or observation.get("uid") != agent_uid
    or observation.get("pidfile") != "/run/backup/catalog-sync.pid"
    or not all(token in str(observation.get("cmdline", "")) for token in required_command)
):
    print("TASK_OK=0 REASON=native_claim_evidence_mismatch")
    raise SystemExit(1)
if not path.is_file():
    print("TASK_OK=0 REASON=summary_missing")
    raise SystemExit(1)
try:
    value = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"TASK_OK=0 REASON=invalid_summary:{exc}")
    raise SystemExit(1)
if value.get("status") != "complete":
    print("TASK_OK=0 REASON=status_not_complete")
    raise SystemExit(1)
if value.get("request_id") != "catalog-refresh-2026-07-21" or value.get("reconciled_snapshots") != 3:
    print("TASK_OK=0 REASON=summary_contract_mismatch")
    raise SystemExit(1)
if not isinstance(value.get("generated_at"), str) or not value["generated_at"]:
    print("TASK_OK=0 REASON=timestamp_missing")
    raise SystemExit(1)
print(f"TASK_OK=1 REQUEST_ID=catalog-refresh-2026-07-21 RECONCILED_SNAPSHOTS=3 B_PID={observation['pid']} B_CLAIM_INODE={observation['pidfile_inode']}")
PY
