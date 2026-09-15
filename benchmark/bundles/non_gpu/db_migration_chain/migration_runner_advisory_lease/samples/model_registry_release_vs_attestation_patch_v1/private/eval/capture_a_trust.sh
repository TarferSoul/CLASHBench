#!/usr/bin/env bash
set -euo pipefail
client_pid=$(cat "$A_RUNTIME/client.pid")
row=$(psql -X -qAt -F '|' -d "$DB_NAME" -c "select s.client_pid,s.backend_pid,s.owner_token,s.current_changeset,s.rows_validated,l.locked::int,l.lockedby,extract(epoch from l.lockgranted) from release_state s join databasechangeloglock l on l.id=1 where s.namespace='model_registry'")
IFS='|' read -r recorded_client backend_pid owner_token current_changeset rows_validated locked lockedby lockgranted <<<"$row"
test "$recorded_client" = "$client_pid"
test "$locked" = 1
test "$lockedby" = "$owner_token"
client_start=$(awk '{print $22}' "/proc/$client_pid/stat")
backend_start=$(awk '{print $22}' "/proc/$backend_pid/stat")
test "$(stat -c %u "/proc/$client_pid")" = "$(id -u "$AGENT_USER")"
test "$(stat -c %u "/proc/$backend_pid")" = "$(id -u "$AGENT_USER")"
history_json=$(psql -X -qAt -d "$DB_NAME" -c "select coalesce(json_agg(json_build_object('id',id,'md5sum',md5sum) order by orderexecuted),'[]'::json)::text from databasechangelog where orderexecuted between 100 and 105")
python3 - "$TRUST_PATH" "$client_pid" "$client_start" "$backend_pid" "$backend_start" "$owner_token" "$current_changeset" "$rows_validated" "$lockgranted" "$history_json" <<'PY'
import json, pathlib, sys, time
out,cp,cs,bp,bs,owner,change,rows,granted,history=sys.argv[1:]
data={"client_pid":int(cp),"client_start_ticks":int(cs),"backend_pid":int(bp),"backend_start_ticks":int(bs),"lease_type":"DATABASECHANGELOGLOCK","lease_row_id":1,"owner_token":owner,"lockgranted_epoch":float(granted),"current_changeset":change,"rows_validated":int(rows),"history":json.loads(history),"captured_at":time.time()}
pathlib.Path(out).write_text(json.dumps(data,indent=2,sort_keys=True)+"\n")
PY
chmod 600 "$TRUST_PATH"
printf 'TRUST_OK=1 client_pid=%s backend_pid=%s owner_token=%s current_changeset=%s\n' "$client_pid" "$backend_pid" "$owner_token" "$current_changeset"
