#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TRUST_ROOT/a.env"

fail() {
  echo "PEER_OK=0 REASON=$1"
  exit 1
}

read -r phase progress state_pid migration db_inode journal_inode started_epoch < <(/usr/bin/python3 - "$MAINTENANCE_STATE" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
print(x.get("phase", ""), x.get("copied_rows", 0), x.get("pid", ""),
      x.get("migration_id", ""), x.get("database_inode", ""),
      x.get("journal_inode", ""), x.get("started_epoch", ""))
PY
)
[ "$state_pid" = "$TRUST_PID" ] || fail state_pid_replaced
[ "$migration" = "$TRUST_MIGRATION_ID" ] || fail migration_replaced
[ "$progress" -ge "$TRUST_PROGRESS" ] || fail progress_regressed
[ "$db_inode" = "$TRUST_DB_INODE" ] || fail database_inode_changed
[ "$(stat -c %i "$LIVE_DB")" = "$TRUST_DB_INODE" ] || fail database_file_replaced
[ "$started_epoch" = "$TRUST_STARTED_EPOCH" ] || fail maintenance_start_changed

if [ "$phase" = committed ]; then
  [ "$progress" = "$LEDGER_ROWS" ] || fail committed_row_count_wrong
  read -r integrity version migration_status migration_rows < <(/usr/bin/python3 - "$LIVE_DB" "$MIGRATION_ID" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
integrity = c.execute("PRAGMA integrity_check").fetchone()[0]
version = c.execute("PRAGMA user_version").fetchone()[0]
status, copied = c.execute(
    "SELECT status, copied_rows FROM schema_migrations WHERE migration_id=?", (sys.argv[2],)
).fetchone()
c.close()
print(integrity, version, status, copied)
PY
)
  [ "$integrity" = ok ] || fail committed_integrity_bad
  [ "$version" = "$TARGET_SCHEMA_VERSION" ] || fail committed_version_wrong
  [ "$migration_status" = committed ] || fail migration_not_committed
  [ "$migration_rows" = "$LEDGER_ROWS" ] || fail migration_rows_wrong
  if kill -0 "$TRUST_PID" 2>/dev/null; then
    [ "$(awk '{print $22}' "/proc/$TRUST_PID/stat")" = "$TRUST_START_TICKS" ] || fail process_replaced
  fi
  echo "PEER_OK=1 PID=$TRUST_PID START_TICKS=$TRUST_START_TICKS MIGRATION_ID=$TRUST_MIGRATION_ID PHASE=committed PROGRESS=$progress DB_INODE=$TRUST_DB_INODE COMPLETION=normal INTEGRITY=$integrity USER_VERSION=$version"
  exit 0
fi

case "$phase" in copying|indexing|validating|swapping) ;; *) fail phase_not_healthy ;; esac
kill -0 "$TRUST_PID" 2>/dev/null || fail process_missing
[ "$(awk '{print $22}' "/proc/$TRUST_PID/stat")" = "$TRUST_START_TICKS" ] || fail process_replaced
[ -f "$LIVE_DB-journal" ] || fail rollback_journal_missing
[ "$journal_inode" = "$TRUST_JOURNAL_INODE" ] || fail journal_identity_changed
[ "$(stat -c %i "$LIVE_DB-journal")" = "$TRUST_JOURNAL_INODE" ] || fail journal_file_replaced

now=$(date +%s)
age=$(/usr/bin/python3 - "$now" "$TRUST_STARTED_EPOCH" <<'PY'
import sys
print(int(float(sys.argv[1]) - float(sys.argv[2])))
PY
)
[ "$age" -le "$A_MAX_MAINTENANCE_SECONDS" ] || fail maintenance_too_old
lock_line=$(awk -v pid="$TRUST_PID" -v inode="$TRUST_DB_INODE" \
  '$4 == "WRITE" && $5 == pid && $6 ~ (":" inode "$") {print; found=1} END {exit !found}' \
  /proc/locks) || fail exclusive_lock_missing

echo "PEER_OK=1 PID=$TRUST_PID START_TICKS=$TRUST_START_TICKS MIGRATION_ID=$TRUST_MIGRATION_ID PHASE=$phase PROGRESS=$progress DB_INODE=$TRUST_DB_INODE JOURNAL_INODE=$TRUST_JOURNAL_INODE AGE_SECONDS=$age LOCK=$(printf '%s' "$lock_line" | tr ' ' '_')"
