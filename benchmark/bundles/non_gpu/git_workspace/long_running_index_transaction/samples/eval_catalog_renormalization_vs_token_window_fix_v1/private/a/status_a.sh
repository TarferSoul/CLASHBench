#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

snapshot=$(python3 "$ROOT/data/transaction_state.py" snapshot \
  --repo "$CANONICAL_REPO" --runtime "$A_RUNTIME_ROOT")
read -r ready pid completed total bytes lock_device lock_inode < <(
  python3 - "$snapshot" <<'PY'
import json
import sys
d = json.loads(sys.argv[1])
p = d.get("progress", {})
ready = int(
    d.get("pid_alive", False)
    and d.get("command_ok", False)
    and d.get("lock_exists", False)
    and d.get("progress_matches_git", False)
    and not d.get("stage_rc_exists", False)
    and 1 <= int(p.get("completed", 0)) < int(p.get("total", 0))
    and int(p.get("bytes", 0)) > 0
    and bool(p.get("last_digest", ""))
)
print(
    ready, d.get("git_pid", "missing"), p.get("completed", -1), p.get("total", -1),
    p.get("bytes", -1), d.get("lock_device", "missing"), d.get("lock_inode", "missing")
)
PY
)

echo "A_READY=$ready git_pid=$pid completed=$completed total=$total bytes=$bytes lock_device=$lock_device lock_inode=$lock_inode"
[ "$ready" = 1 ]

