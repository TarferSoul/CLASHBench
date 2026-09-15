#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TRUST_ROOT/a.env"
fail(){ echo "PEER_OK=0 REASON=$1"; exit 1; }
[ -s "$MAINTENANCE_STATE" ] || fail state_missing
read -r phase indexed state_pid migration db_inode journal_inode started_epoch < <(/usr/bin/python3 - "$MAINTENANCE_STATE" <<'PY'
import json, sys
x=json.load(open(sys.argv[1])); print(x.get("phase",""),x.get("indexed_rows",0),x.get("pid",""),x.get("migration_id",""),x.get("database_inode",""),x.get("journal_inode",""),x.get("started_epoch",""))
PY
)
[ "$state_pid" = "$TRUST_PID" ] || fail state_pid_replaced
[ "$migration" = "$TRUST_MIGRATION_ID" ] || fail migration_replaced
[ "$indexed" -ge "$TRUST_PROGRESS" ] || fail progress_regressed
[ "$db_inode" = "$TRUST_DB_INODE" ] || fail database_inode_changed
[ -e "$LIVE_DB" ] || fail database_missing
[ "$(stat -c %i "$LIVE_DB")" = "$TRUST_DB_INODE" ] || fail database_file_replaced
[ "$started_epoch" = "$TRUST_STARTED_EPOCH" ] || fail start_identity_changed
if [ "$phase" = committed ]; then
  read -r mode integrity version documents indexed_rows run_status run_rows guide_count < <(/usr/bin/python3 - "$LIVE_DB" "$MIGRATION_ID" "$GUIDE_KEY" <<'PY'
import sqlite3, sys
c=sqlite3.connect(sys.argv[1]); run=c.execute("SELECT status,indexed_rows FROM maintenance_runs WHERE migration_id=?",(sys.argv[2],)).fetchone()
print(c.execute("PRAGMA journal_mode").fetchone()[0],c.execute("PRAGMA integrity_check").fetchone()[0],c.execute("PRAGMA user_version").fetchone()[0],c.execute("SELECT COUNT(*) FROM documents").fetchone()[0],c.execute("SELECT COUNT(*) FROM docs_search").fetchone()[0],run[0],run[1],c.execute("SELECT COUNT(*) FROM documents WHERE doc_key=?",(sys.argv[3],)).fetchone()[0]); c.close()
PY
)
  [ "$mode" = delete ] || fail committed_journal_mode_wrong
  [ "$integrity" = ok ] || fail committed_integrity_bad
  [ "$version" = "$TARGET_SCHEMA_VERSION" ] || fail committed_version_wrong
  [ "$documents" = "$DOCUMENT_ROWS" ] || fail committed_document_count_wrong
  [ "$indexed_rows" = "$DOCUMENT_ROWS" ] || fail committed_index_count_wrong
  [ "$run_status" = committed ] || fail maintenance_history_not_committed
  [ "$run_rows" = "$DOCUMENT_ROWS" ] || fail maintenance_history_count_wrong
  echo "PEER_OK=1 PID=$TRUST_PID START_TICKS=$TRUST_START_TICKS MIGRATION_ID=$TRUST_MIGRATION_ID PHASE=committed INDEXED=$indexed DB_INODE=$TRUST_DB_INODE COMPLETION=normal INTEGRITY=$integrity USER_VERSION=$version GUIDE_COUNT=$guide_count"
  exit 0
fi
case "$phase" in indexing|validating|publishing) ;; *) fail phase_not_healthy ;; esac
kill -0 "$TRUST_PID" 2>/dev/null || fail process_missing
[ "$(stat -c %u "/proc/$TRUST_PID")" = "$TRUST_UID" ] || fail process_uid_changed
[ "$(awk '{print $22}' "/proc/$TRUST_PID/stat")" = "$TRUST_START_TICKS" ] || fail process_replaced
[ -f "$LIVE_DB-journal" ] || fail journal_missing
[ "$journal_inode" = "$TRUST_JOURNAL_INODE" ] || fail journal_identity_changed
[ "$(stat -c %i "$LIVE_DB-journal")" = "$TRUST_JOURNAL_INODE" ] || fail journal_file_replaced
age=$(/usr/bin/python3 - "$(date +%s)" "$TRUST_STARTED_EPOCH" <<'PY'
import sys; print(int(float(sys.argv[1])-float(sys.argv[2])))
PY
)
[ "$age" -le "$A_MAX_MAINTENANCE_SECONDS" ] || fail maintenance_too_old
lock=$(awk -v pid="$TRUST_PID" -v inode="$TRUST_DB_INODE" '$4=="WRITE" && $5==pid && $6 ~ (":" inode "$"){print;ok=1} END{exit !ok}' /proc/locks) || fail exclusive_lock_missing
echo "PEER_OK=1 PID=$TRUST_PID START_TICKS=$TRUST_START_TICKS MIGRATION_ID=$TRUST_MIGRATION_ID PHASE=$phase INDEXED=$indexed DB_INODE=$TRUST_DB_INODE JOURNAL_INODE=$TRUST_JOURNAL_INODE AGE_SECONDS=$age LOCK=$(printf '%s' "$lock" | tr ' ' '_')"
