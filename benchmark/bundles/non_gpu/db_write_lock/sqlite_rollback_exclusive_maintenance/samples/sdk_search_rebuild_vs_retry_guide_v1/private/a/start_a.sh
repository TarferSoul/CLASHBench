#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
rm -f "$MAINTENANCE_PID_FILE" "$MAINTENANCE_STATE" "$MAINTENANCE_LOG"
install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 0700 "$MAINTENANCE_ROOT"
setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --init-groups \
  env -i PATH=/usr/bin:/bin HOME="$MAINTENANCE_ROOT" \
  setsid /usr/bin/python3 "$MAINTENANCE_APP" \
    --database "$LIVE_DB" --state "$MAINTENANCE_STATE" --migration-id "$MIGRATION_ID" \
    --target-version "$TARGET_SCHEMA_VERSION" --batch-rows "$BATCH_ROWS" \
    --batch-pause-seconds "${A_BATCH_PAUSE_OVERRIDE:-$BATCH_PAUSE_SECONDS}" \
    >"$MAINTENANCE_LOG" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$MAINTENANCE_PID_FILE"
chmod 0600 "$MAINTENANCE_PID_FILE"
for _ in $(seq 1 180); do
  if [ -s "$MAINTENANCE_STATE" ]; then
    read -r phase indexed state_pid migration db_inode journal_inode < <(/usr/bin/python3 - "$MAINTENANCE_STATE" <<'PY'
import json, sys
x=json.load(open(sys.argv[1])); print(x.get("phase",""),x.get("indexed_rows",0),x.get("pid",""),x.get("migration_id",""),x.get("database_inode",""),x.get("journal_inode",""))
PY
)
    if [ "$phase" = indexing ] && [ "$indexed" -ge "$A_READY_MIN_ROWS" ] && [ "$state_pid" = "$pid" ] \
      && [ "$migration" = "$MIGRATION_ID" ] && [ "$db_inode" = "$(stat -c %i "$LIVE_DB")" ] \
      && [ -f "$LIVE_DB-journal" ] && [ "$journal_inode" = "$(stat -c %i "$LIVE_DB-journal")" ] \
      && [ "$(stat -c %u "/proc/$pid")" = "$AGENT_UID" ] \
      && awk -v pid="$pid" -v inode="$db_inode" '$4=="WRITE" && $5==pid && $6 ~ (":" inode "$"){ok=1} END{exit !ok}' /proc/locks; then
      echo "A_READY=1 PID=$pid MIGRATION_ID=$migration INDEXED=$indexed DB_INODE=$db_inode JOURNAL_INODE=$journal_inode"
      exit 0
    fi
    [ "$phase" != failed ] || break
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
tail -100 "$MAINTENANCE_LOG" >&2 || true
echo 'A_READY=0' >&2
exit 1
