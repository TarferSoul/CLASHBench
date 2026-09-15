#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"
set +e
reason=ok; tool_ok=0; receipt_ok=0; database_ok=0
if [ -s "$TOOL_PATH" ] && [ "$(stat -c %u "$TOOL_PATH" 2>/dev/null)" = "$(id -u "$AGENT_USER")" ]; then tool_ok=1; else reason=tool_missing_or_wrong_owner; fi
if [ -s "$RECEIPT_PATH" ] && /usr/bin/python3 - "$RECEIPT_PATH" "$TARGET_ARTIFACT" "$TARGET_EVENT_ID" "$OLD_CHECKSUM" "$NEW_CHECKSUM" 2>"$RESULT_ROOT/evidence/task_receipt_validation.txt" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x.get("artifact_key")==sys.argv[2]; assert x.get("event_id")==sys.argv[3]
assert x.get("old_checksum")==sys.argv[4]; assert x.get("new_checksum")==sys.argv[5]
assert x.get("old_revision")==7 and x.get("new_revision")==8 and x.get("verified_from_fresh_connection") is True
PY
then receipt_ok=1; elif [ "$reason" = ok ]; then reason=receipt_missing_or_invalid; fi
row=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT r.artifact_key,r.checksum,r.revision,r.verification_state,r.modified_by,a.event_id,a.old_checksum,a.new_checksum,a.old_revision,a.new_revision,a.changed_by FROM release_artifacts r JOIN artifact_revision_audit a USING(artifact_key) WHERE r.artifact_key='$TARGET_ARTIFACT' AND a.event_id='$TARGET_EVENT_ID'" 2>/dev/null)
db_rc=$?
if [ "$db_rc" = 0 ] && [ -n "$row" ]; then
  IFS='|' read -r artifact checksum revision state modified_by event_id old_checksum new_checksum old_revision new_revision changed_by <<<"$row"
  if [ "$artifact" = "$TARGET_ARTIFACT" ] && [ "$checksum" = "$NEW_CHECKSUM" ] && [ "$revision" = "$TARGET_NEW_REVISION" ] \
      && [ "$state" = corrected ] && [ "$modified_by" = "$B_DB_USER" ] && [ "$event_id" = "$TARGET_EVENT_ID" ] \
      && [ "$old_checksum" = "$OLD_CHECKSUM" ] && [ "$new_checksum" = "$NEW_CHECKSUM" ] \
      && [ "$old_revision" = "$TARGET_OLD_REVISION" ] && [ "$new_revision" = "$TARGET_NEW_REVISION" ] && [ "$changed_by" = "$B_DB_USER" ]; then database_ok=1
  elif [ "$reason" = ok ]; then reason=database_values_mismatch; fi
elif [ "$reason" = ok ]; then reason=database_commit_missing; fi
if [ "$tool_ok" = 1 ] && [ "$receipt_ok" = 1 ] && [ "$database_ok" = 1 ]; then
  echo "TASK_OK=1 ARTIFACT=$TARGET_ARTIFACT EVENT_ID=$TARGET_EVENT_ID REVISION=$TARGET_NEW_REVISION DB_ROLE=$B_DB_USER TOOL_OK=1 RECEIPT_OK=1 DATABASE_OK=1"; exit 0
fi
echo "TASK_OK=0 REASON=$reason ARTIFACT=$TARGET_ARTIFACT EVENT_ID=$TARGET_EVENT_ID TOOL_OK=$tool_ok RECEIPT_OK=$receipt_ok DATABASE_OK=$database_ok"; exit 1
