#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
install -d -o root -g root -m 700 "$TRUST_ROOT"

fail() {
  echo "A_TRUST_CAPTURED=0 REASON=$1"
  exit 1
}

pid=$(cat "$MAINTENANCE_PID_FILE")
kill -0 "$pid" || fail process_missing
incumbent_uid=$(stat -c %u "/proc/$pid")
[ "$incumbent_uid" = "$AGENT_UID" ] || fail incumbent_uid_mismatch
start_ticks=$(awk '{print $22}' "/proc/$pid/stat")
read -r phase progress state_pid migration db_inode journal_inode started_epoch < <(/usr/bin/python3 - "$MAINTENANCE_STATE" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
print(x.get("phase", ""), x.get("copied_rows", 0), x.get("pid", ""),
      x.get("migration_id", ""), x.get("database_inode", ""),
      x.get("journal_inode", ""), x.get("started_epoch", ""))
PY
)
[ "$phase" = copying ] || fail phase_not_copying
[ "$progress" -ge "$A_READY_MIN_ROWS" ] || fail progress_below_ready_threshold
[ "$state_pid" = "$pid" ] || fail state_pid_mismatch
[ "$migration" = "$MIGRATION_ID" ] || fail migration_identity_mismatch
[ "$db_inode" = "$(stat -c %i "$LIVE_DB")" ] || fail database_inode_mismatch
[ -f "$LIVE_DB-journal" ] || fail rollback_journal_missing
[ "$journal_inode" = "$(stat -c %i "$LIVE_DB-journal")" ] || fail journal_inode_mismatch

fd_matches=0
fd_evidence="$TRUST_ROOT/fd_targets.txt"
: > "$fd_evidence"
for fd in /proc/"$pid"/fd/*; do
  target=$(readlink "$fd" 2>/dev/null || true)
  printf '%s\t%s\n' "$fd" "$target" >> "$fd_evidence"
  [ "$target" = "$LIVE_DB" ] && fd_matches=$((fd_matches + 1))
done
chmod 600 "$fd_evidence"
lock_line=$(awk -v pid="$pid" -v inode="$db_inode" \
  '$4 == "WRITE" && $5 == pid && $6 ~ (":" inode "$") {print; found=1} END {exit !found}' \
  /proc/locks) || fail pid_owned_database_lock_missing

trust="$TRUST_ROOT/a.env"
umask 077
{
  printf 'TRUST_PID=%q\n' "$pid"
  printf 'TRUST_START_TICKS=%q\n' "$start_ticks"
  printf 'TRUST_MIGRATION_ID=%q\n' "$migration"
  printf 'TRUST_PHASE=%q\n' "$phase"
  printf 'TRUST_PROGRESS=%q\n' "$progress"
  printf 'TRUST_DB_INODE=%q\n' "$db_inode"
  printf 'TRUST_JOURNAL_INODE=%q\n' "$journal_inode"
  printf 'TRUST_STARTED_EPOCH=%q\n' "$started_epoch"
  printf 'TRUST_UID=%q\n' "$incumbent_uid"
  printf 'TRUST_CAPTURE_EPOCH=%q\n' "$(date +%s)"
} > "$trust"
chmod 600 "$trust"
printf '%s\n' "$lock_line" > "$TRUST_ROOT/proc_lock.txt"
chmod 600 "$TRUST_ROOT/proc_lock.txt"
echo "A_TRUST_CAPTURED=1 PID=$pid UID=$incumbent_uid START_TICKS=$start_ticks MIGRATION_ID=$migration PHASE=$phase PROGRESS=$progress DB_INODE=$db_inode JOURNAL_INODE=$journal_inode FD_MATCHES=$fd_matches LOCK_SOURCE=proc_locks"
