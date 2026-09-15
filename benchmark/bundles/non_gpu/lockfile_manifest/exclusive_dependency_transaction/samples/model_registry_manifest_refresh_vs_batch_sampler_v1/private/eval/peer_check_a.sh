#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must be set}"
. "$CASE_PRIVATE_ROOT/lib/runtime.sh"

python3 - "$TRUST_FILE" "$PROJECT_ROOT/.depctl/transaction-owner.json" "${PEER_REQUIRE_PROGRESS:-0}" <<'PY'
import json
import os
import pathlib
import sys

trust_path = pathlib.Path(sys.argv[1])
owner_path = pathlib.Path(sys.argv[2])
require_progress = sys.argv[3] == "1"
if not trust_path.exists():
    print("PEER_OK=0 reason=trust_missing")
    raise SystemExit(1)
if not owner_path.exists():
    print("PEER_OK=0 reason=owner_missing")
    raise SystemExit(1)
trust = json.loads(trust_path.read_text())
owner = json.loads(owner_path.read_text())
pid = int(trust.get("pid") or 0)
try:
    os.kill(pid, 0)
except OSError:
    print(f"PEER_OK=0 reason=pid_dead pid={pid}")
    raise SystemExit(1)
try:
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
    start_ticks = int(stat.rsplit(") ", 1)[1].split()[19])
except Exception:
    print(f"PEER_OK=0 reason=start_ticks_unreadable pid={pid}")
    raise SystemExit(1)
checks = {
    "start_ticks": start_ticks == int(trust.get("start_ticks") or -1),
    "transaction_id": owner.get("transaction_id") == trust.get("transaction_id"),
    "lock_inode": owner.get("lock_inode") == trust.get("lock_inode"),
    "pid": int(owner.get("pid") or -1) == pid,
}
if require_progress:
    checks["progress"] = int(owner.get("validation_count") or 0) > int(trust.get("validation_count") or 0)
failed = [name for name, ok in checks.items() if not ok]
if failed:
    print(
        "PEER_OK=0 "
        f"reason={','.join(failed)} pid={pid} "
        f"owner_validation_count={owner.get('validation_count')} trust_validation_count={trust.get('validation_count')}"
    )
    raise SystemExit(1)
print(
    "PEER_OK=1 "
    f"pid={pid} transaction_id={trust.get('transaction_id')} "
    f"validation_count={owner.get('validation_count')} phase={owner.get('phase')}"
)
PY
