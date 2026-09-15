#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"
test -s "$PID_FILE" -a -s "$STATE_FILE"
pid=$(cat "$PID_FILE")
kill -0 "$pid"
values=$(/usr/bin/python3 - "$STATE_FILE" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
print(x.get("phase", ""), x.get("progress", -1), x.get("backend_pid", ""),
      x.get("transaction_id", ""), x.get("snapshot_id", ""), x.get("closeout_id", ""))
PY
)
read -r phase progress backend_pid transaction_id snapshot_id closeout_id <<<"$values"
case "$phase" in relation_lock_acquired|partition_digest_validation|snapshot_consistency_recheck) ;; *) exit 1 ;; esac
test "$progress" -ge "$A_READY_MIN_PROGRESS"
test "$snapshot_id" = "$SNAPSHOT_ID" -a "$closeout_id" = "$CLOSEOUT_ID"
test "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")"
test "$(stat -c %u "/proc/$backend_pid")" = "$(id -u "$AGENT_USER")"
lock=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_locks WHERE pid=$backend_pid AND relation='$LOCK_RELATION'::regclass AND mode='ShareRowExclusiveLock' AND granted")
test "$lock" = 1
echo "A_READY=1 PID=$pid BACKEND_PID=$backend_pid TRANSACTION_ID=$transaction_id SNAPSHOT_ID=$snapshot_id CLOSEOUT_ID=$closeout_id PHASE=$phase PROGRESS=$progress"
