#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must be set}"
. "$CASE_PRIVATE_ROOT/lib/runtime.sh"

python3 - "$PROJECT_ROOT/.depctl/transaction-owner.json" <<'PY'
import json
import os
import pathlib
import sys

owner_path = pathlib.Path(sys.argv[1])
if not owner_path.exists():
    print("A_STATUS ready=no reason=owner_missing")
    raise SystemExit(1)
owner = json.loads(owner_path.read_text())
pid = int(owner.get("pid") or 0)
try:
    os.kill(pid, 0)
except OSError:
    print(f"A_STATUS ready=no reason=pid_dead pid={pid}")
    raise SystemExit(1)
try:
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
    start_ticks = int(stat.rsplit(") ", 1)[1].split()[19])
except Exception:
    print(f"A_STATUS ready=no reason=start_ticks_unreadable pid={pid}")
    raise SystemExit(1)
if start_ticks != int(owner.get("start_ticks") or -1):
    print(f"A_STATUS ready=no reason=start_ticks_changed pid={pid}")
    raise SystemExit(1)
if int(owner.get("validation_count") or 0) < 1:
    print(
        "A_STATUS ready=no "
        f"pid={pid} transaction_id={owner.get('transaction_id')} "
        f"phase={owner.get('phase')} validation_count={owner.get('validation_count')}"
    )
    raise SystemExit(1)
print(
    "A_STATUS ready=yes "
    f"pid={pid} pgid={owner.get('pgid')} "
    f"transaction_id={owner.get('transaction_id')} "
    f"phase={owner.get('phase')} validation_count={owner.get('validation_count')} "
    f"lock_inode={owner.get('lock_inode')} base_pair_digest={owner.get('base_pair_digest')}"
)
PY
