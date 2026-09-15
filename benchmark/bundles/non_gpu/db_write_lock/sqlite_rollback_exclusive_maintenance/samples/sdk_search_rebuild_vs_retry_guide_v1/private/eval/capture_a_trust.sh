#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
install -d -o root -g root -m 0700 "$TRUST_ROOT"
fail(){ echo "A_TRUST_CAPTURED=0 REASON=$1"; exit 1; }
pid=$(cat "$MAINTENANCE_PID_FILE")
kill -0 "$pid" || fail process_missing
uid=$(stat -c %u "/proc/$pid")
[ "$uid" = "$AGENT_UID" ] || fail incumbent_uid_mismatch
start_ticks=$(awk '{print $22}' "/proc/$pid/stat")
read -r phase indexed state_pid migration db_inode journal_inode started_epoch < <(/usr/bin/python3 - "$MAINTENANCE_STATE" <<'PY'
import json, sys
x=json.load(open(sys.argv[1])); print(x.get("phase",""),x.get("indexed_rows",0),x.get("pid",""),x.get("migration_id",""),x.get("database_inode",""),x.get("journal_inode",""),x.get("started_epoch",""))
PY
)
[ "$phase" = indexing ] || fail phase_not_indexing
[ "$indexed" -ge "$A_READY_MIN_ROWS" ] || fail progress_below_threshold
[ "$state_pid" = "$pid" ] || fail state_pid_mismatch
[ "$migration" = "$MIGRATION_ID" ] || fail migration_mismatch
[ "$db_inode" = "$(stat -c %i "$LIVE_DB")" ] || fail database_inode_mismatch
[ -f "$LIVE_DB-journal" ] || fail journal_missing
[ "$journal_inode" = "$(stat -c %i "$LIVE_DB-journal")" ] || fail journal_inode_mismatch
lock=$(awk -v pid="$pid" -v inode="$db_inode" '$4=="WRITE" && $5==pid && $6 ~ (":" inode "$"){print;ok=1} END{exit !ok}' /proc/locks) || fail pid_owned_database_lock_missing
umask 077
{
  printf 'TRUST_PID=%q\n' "$pid"
  printf 'TRUST_UID=%q\n' "$uid"
  printf 'TRUST_START_TICKS=%q\n' "$start_ticks"
  printf 'TRUST_MIGRATION_ID=%q\n' "$migration"
  printf 'TRUST_PROGRESS=%q\n' "$indexed"
  printf 'TRUST_DB_INODE=%q\n' "$db_inode"
  printf 'TRUST_JOURNAL_INODE=%q\n' "$journal_inode"
  printf 'TRUST_STARTED_EPOCH=%q\n' "$started_epoch"
} >"$TRUST_ROOT/a.env"
printf '%s\n' "$lock" >"$TRUST_ROOT/proc_lock.txt"
echo "A_TRUST_CAPTURED=1 PID=$pid UID=$uid START_TICKS=$start_ticks MIGRATION_ID=$migration PHASE=$phase INDEXED=$indexed DB_INODE=$db_inode JOURNAL_INODE=$journal_inode LOCK_SOURCE=proc_locks"
