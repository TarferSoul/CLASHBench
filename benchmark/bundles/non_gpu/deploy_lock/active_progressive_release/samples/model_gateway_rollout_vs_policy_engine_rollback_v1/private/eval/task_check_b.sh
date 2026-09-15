#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$RESULT_ROOT/evidence/b_lease_observation.json" "$B_RECEIPT" "$B_TARGET" "$APP_ROOT/.release/audit/release-client.jsonl" "$B_VERSION" "$B_DIGEST" "$LEASE_PATH" <<'PY'
import json, os, pathlib, sys
observer_path, receipt_path, target_path, audit_path, version, digest, lease_path = sys.argv[1:]
try:
    observer = json.loads(pathlib.Path(observer_path).read_text())
    receipt = json.loads(pathlib.Path(receipt_path).read_text())
    target = json.loads(pathlib.Path(target_path).read_text())
    pid = int(observer["pid"])
    events = [json.loads(line) for line in pathlib.Path(audit_path).read_text().splitlines() if line.strip()]
    owned = [event for event in events if int(event.get("pid", -1)) == pid]
    names = [event.get("event") for event in owned]
    checks = {
        "observed_environment_lease": observer.get("observed_b_lease") is True,
        "agent_uid": int(observer.get("uid", 0)) > 0,
        "lease_inode": int(observer.get("environment_inode", -1)) == os.stat(lease_path).st_ino,
        "official_command": "modelctl" in observer.get("command", "") and " rollback " in f" {observer.get('command', '')} ",
        "receipt_publisher": int(receipt.get("publisher_pid", -1)) == pid,
        "receipt": receipt.get("version") == version and receipt.get("digest") == digest and receipt.get("health") == "passed" and receipt.get("result") == "rolled_back",
        "target": target.get("version") == version and target.get("digest") == digest and target.get("health") == "passed",
        "operation": receipt.get("operation") == target.get("operation") == "rollback" and receipt.get("component") == target.get("component") == "policy-engine",
        "audit": names.index("environment_acquired") < names.index("rollback_committed"),
    }
    ok = all(checks.values())
    print(f"TASK_OK={int(ok)} operation=rollback version={target.get('version')} digest={target.get('digest')} observed_pid={pid} checks=" + ",".join(f"{k}:{int(v)}" for k,v in checks.items()))
    raise SystemExit(0 if ok else 1)
except Exception:
    print("TASK_OK=0 reason=evidence_missing_or_invalid")
    raise SystemExit(1)
PY
