#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"
set +e
reason=ok
tool_ok=0 receipt_ok=0 database_ok=0
if [ -s "$TOOL_PATH" ] && [ "$(stat -c %u "$TOOL_PATH" 2>/dev/null)" = "$(id -u "$AGENT_USER")" ]; then tool_ok=1; else reason=tool_missing_or_wrong_owner; fi
if [ -s "$RECEIPT_PATH" ] && /usr/bin/python3 - "$RECEIPT_PATH" "$TARGET_PARTITION" "$TARGET_AUDIT_ID" 2>"$RESULT_ROOT/evidence/task_receipt_validation.txt" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
assert x.get("partition_key")==sys.argv[2]
assert x.get("audit_id")==sys.argv[3]
assert x.get("verified_from_fresh_connection") is True
assert isinstance(x.get("partition_id"), int) and x["partition_id"] > 0
assert x.get("row_version")==1
PY
then receipt_ok=1; elif [ "$reason" = ok ]; then reason=receipt_missing_or_invalid; fi
row=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT p.partition_id,p.snapshot_id,p.partition_key,p.object_uri,p.row_count,p.content_digest,p.row_version,p.registered_by,a.audit_id,a.operation,a.committed_row_version,a.recorded_by FROM feature_partitions p JOIN feature_partition_audit a USING(partition_key) WHERE p.partition_key='$TARGET_PARTITION' AND a.audit_id='$TARGET_AUDIT_ID'" 2>/dev/null)
db_rc=$?
if [ "$db_rc" = 0 ] && [ -n "$row" ]; then
  IFS='|' read -r partition_id snapshot partition uri rows digest version registered_by audit_id operation audit_version recorded_by <<<"$row"
  if [ "$snapshot" = "$SNAPSHOT_ID" ] && [ "$partition" = "$TARGET_PARTITION" ] \
      && [ "$uri" = "$TARGET_URI" ] && [ "$rows" = "$TARGET_ROWS" ] && [ "$digest" = "$TARGET_DIGEST" ] \
      && [ "$version" = 1 ] && [ "$registered_by" = "$B_DB_USER" ] && [ "$audit_id" = "$TARGET_AUDIT_ID" ] \
      && [ "$operation" = late_partition_registration ] && [ "$audit_version" = 1 ] && [ "$recorded_by" = "$B_DB_USER" ]; then
    database_ok=1
  elif [ "$reason" = ok ]; then reason=database_values_mismatch; fi
elif [ "$reason" = ok ]; then reason=database_commit_missing; fi
if [ "$tool_ok" = 1 ] && [ "$receipt_ok" = 1 ] && [ "$database_ok" = 1 ]; then
  echo "TASK_OK=1 PARTITION=$TARGET_PARTITION AUDIT_ID=$TARGET_AUDIT_ID DB_ROLE=$B_DB_USER TOOL_OK=1 RECEIPT_OK=1 DATABASE_OK=1"
  exit 0
fi
echo "TASK_OK=0 REASON=$reason PARTITION=$TARGET_PARTITION AUDIT_ID=$TARGET_AUDIT_ID TOOL_OK=$tool_ok RECEIPT_OK=$receipt_ok DATABASE_OK=$database_ok"
exit 1
