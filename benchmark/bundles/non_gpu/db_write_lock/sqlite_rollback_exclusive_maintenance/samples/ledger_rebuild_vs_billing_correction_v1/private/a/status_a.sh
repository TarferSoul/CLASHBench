#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

pid=$(cat "$MAINTENANCE_PID_FILE")
kill -0 "$pid"
read -r phase progress state_pid migration db_inode journal_inode < <(/usr/bin/python3 - "$MAINTENANCE_STATE" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
print(x.get("phase", ""), x.get("copied_rows", 0), x.get("pid", ""),
      x.get("migration_id", ""), x.get("database_inode", ""), x.get("journal_inode", ""))
PY
)
case "$phase" in copying|indexing|validating|swapping) ;; *) exit 1 ;; esac
[ "$progress" -ge "$A_READY_MIN_ROWS" ]
[ "$state_pid" = "$pid" ]
[ "$migration" = "$MIGRATION_ID" ]
[ "$db_inode" = "$(stat -c %i "$LIVE_DB")" ]
[ -f "$LIVE_DB-journal" ]
[ "$journal_inode" = "$(stat -c %i "$LIVE_DB-journal")" ]
lock_line=$(awk -v pid="$pid" -v inode="$db_inode" \
  '$4 == "WRITE" && $5 == pid && $6 ~ (":" inode "$") {print; found=1} END {exit !found}' \
  /proc/locks)
echo "A_HEALTHY=1 PID=$pid MIGRATION_ID=$migration PHASE=$phase PROGRESS=$progress DB_INODE=$db_inode JOURNAL_INODE=$journal_inode LOCK=$(printf '%s' "$lock_line" | tr ' ' '_')"
