#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must be set}"
. "$CASE_PRIVATE_ROOT/lib/runtime.sh"

python3 - "$PROJECT_ROOT/.depctl/transaction-owner.json" "$TRUST_FILE" <<'PY'
import json
import os
import pathlib
import sys
import time

owner_path = pathlib.Path(sys.argv[1])
trust_path = pathlib.Path(sys.argv[2])
if not owner_path.exists():
    print("A_TRUST_CAPTURED=0 reason=owner_missing")
    raise SystemExit(1)
first = json.loads(owner_path.read_text())
time.sleep(0.5)
second = json.loads(owner_path.read_text())
pid = int(second.get("pid") or 0)
try:
    os.kill(pid, 0)
except OSError:
    print(f"A_TRUST_CAPTURED=0 reason=pid_dead pid={pid}")
    raise SystemExit(1)
trust = {
    "pid": pid,
    "pgid": int(second.get("pgid") or 0),
    "start_ticks": int(second.get("start_ticks") or 0),
    "transaction_id": second.get("transaction_id"),
    "base_pair_digest": second.get("base_pair_digest"),
    "current_pair_digest": second.get("current_pair_digest"),
    "lock_dev": second.get("lock_dev"),
    "lock_inode": second.get("lock_inode"),
    "phase": second.get("phase"),
    "validation_count": int(second.get("validation_count") or 0),
    "previous_validation_count": int(first.get("validation_count") or 0),
    "staging_dir": second.get("staging_dir"),
    "captured_at": time.time(),
}
trust_path.parent.mkdir(parents=True, exist_ok=True)
trust_path.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
print(
    "A_TRUST_CAPTURED=1 "
    f"pid={trust['pid']} pgid={trust['pgid']} "
    f"transaction_id={trust['transaction_id']} lock_inode={trust['lock_inode']} "
    f"validation_count={trust['validation_count']} phase={trust['phase']}"
)
PY
