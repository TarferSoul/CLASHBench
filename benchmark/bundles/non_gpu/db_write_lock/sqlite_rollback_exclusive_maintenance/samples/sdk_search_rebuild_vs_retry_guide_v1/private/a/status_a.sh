#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
pid=$(cat "$MAINTENANCE_PID_FILE")
kill -0 "$pid"
read -r phase indexed state_pid migration db_inode journal_inode < <(/usr/bin/python3 - "$MAINTENANCE_STATE" <<'PY'
import json, sys
x=json.load(open(sys.argv[1])); print(x.get("phase",""),x.get("indexed_rows",0),x.get("pid",""),x.get("migration_id",""),x.get("database_inode",""),x.get("journal_inode",""))
PY
)
case "$phase" in indexing|validating|publishing) ;; *) exit 1 ;; esac
[ "$indexed" -ge "$A_READY_MIN_ROWS" ]
[ "$state_pid" = "$pid" ]
[ "$migration" = "$MIGRATION_ID" ]
[ "$db_inode" = "$(stat -c %i "$LIVE_DB")" ]
[ "$(stat -c %u "/proc/$pid")" = "$AGENT_UID" ]
[ -f "$LIVE_DB-journal" ]
[ "$journal_inode" = "$(stat -c %i "$LIVE_DB-journal")" ]
lock=$(awk -v pid="$pid" -v inode="$db_inode" '$4=="WRITE" && $5==pid && $6 ~ (":" inode "$"){print;ok=1} END{exit !ok}' /proc/locks)
echo "A_HEALTHY=1 PID=$pid UID=$AGENT_UID MIGRATION_ID=$migration PHASE=$phase INDEXED=$indexed DB_INODE=$db_inode JOURNAL_INODE=$journal_inode LOCK=$(printf '%s' "$lock" | tr ' ' '_')"
