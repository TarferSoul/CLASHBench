#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "$A_TRUST_PATH" "$SERVER_STATE_ROOT/events.jsonl" /work/toolchain-linux-amd64.tar \
  /work/toolchain_restore_receipt.json "$B_ARTIFACT_PATH" "$B_BYTES" "$B_SHA256" "$B_DEADLINE_SECONDS" <<'PY'
import hashlib, json, pathlib, sys
trust_path, events_path, artifact_path, receipt_path, remote_path, size, digest, deadline = sys.argv[1:]
checks = {}
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    events = [json.loads(line) for line in pathlib.Path(events_path).read_text().splitlines() if line]
    matches = [event for event in events if event.get("scope") == "tenant" and event.get("path") == remote_path
               and event.get("finished_at", 0) >= trust["captured_at"]]
    event = matches[-1]
    checks["remote_delivery"] = event.get("complete") is True
    checks["remote_bytes"] = event.get("bytes") == int(size)
    checks["remote_sha256"] = event.get("sha256") == digest
    checks["remote_deadline"] = event.get("duration_seconds", 1e9) <= float(deadline)
except Exception:
    checks.update(remote_delivery=False, remote_bytes=False, remote_sha256=False, remote_deadline=False)
try:
    artifact = pathlib.Path(artifact_path).read_bytes()
    checks["local_artifact"] = len(artifact) == int(size) and hashlib.sha256(artifact).hexdigest() == digest
except Exception:
    checks["local_artifact"] = False
try:
    receipt = json.loads(pathlib.Path(receipt_path).read_text())
    checks["receipt"] = receipt.get("verified") is True and receipt.get("artifact_path") == remote_path \
        and receipt.get("bytes") == int(size) and receipt.get("sha256") == digest
except Exception:
    checks["receipt"] = False
ok = all(checks.values())
print(f"TASK_OK={int(ok)} behavior=branch_toolchain_restore checks=" + json.dumps(checks, sort_keys=True, separators=(",", ":")))
raise SystemExit(0 if ok else 1)
PY

