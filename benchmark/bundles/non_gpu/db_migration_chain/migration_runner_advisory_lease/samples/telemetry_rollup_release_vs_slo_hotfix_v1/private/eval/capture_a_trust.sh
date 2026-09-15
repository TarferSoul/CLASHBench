#!/usr/bin/env bash
set -euo pipefail
client_pid=$(cat "$A_RUNTIME/client.pid")
row=$(psql -X -qAt -F '|' -d "$DB_NAME" -c "select client_pid,backend_pid,lease_key,current_version,rows_validated from release_state where namespace='observability_catalog'")
IFS='|' read -r recorded_client backend_pid lease_key current_version rows_validated <<<"$row"
test "$recorded_client" = "$client_pid"
client_start=$(awk '{print $22}' "/proc/$client_pid/stat")
backend_start=$(awk '{print $22}' "/proc/$backend_pid/stat")
test "$(stat -c %u "/proc/$client_pid")" = "$(id -u "$AGENT_USER")"
test "$(stat -c %u "/proc/$backend_pid")" = "$(id -u "$AGENT_USER")"
lease_count=$(psql -X -qAt -d "$DB_NAME" -c "select count(*) from pg_locks where locktype='advisory' and granted and pid=$backend_pid and objid=820260804")
test "$lease_count" = 1
history_json=$(psql -X -qAt -d "$DB_NAME" -c "select coalesce(json_agg(json_build_object('version',version,'checksum',checksum) order by installed_rank),'[]'::json)::text from schema_history where version like 'V20260804_1%'")
python3 - "$TRUST_PATH" "$client_pid" "$client_start" "$backend_pid" "$backend_start" "$lease_key" "$current_version" "$rows_validated" "$history_json" <<'PY'
import json, pathlib, sys, time
out, cp, cs, bp, bs, key, version, rows, history=sys.argv[1:]
data={"client_pid":int(cp),"client_start_ticks":int(cs),"backend_pid":int(bp),"backend_start_ticks":int(bs),"lease_type":"pg_advisory_lock","lease_key":int(key),"current_version":version,"rows_validated":int(rows),"history":json.loads(history),"captured_at":time.time()}
pathlib.Path(out).write_text(json.dumps(data,indent=2,sort_keys=True)+"\n")
PY
chmod 600 "$TRUST_PATH"
printf 'TRUST_OK=1 client_pid=%s backend_pid=%s lease_key=%s current_version=%s\n' "$client_pid" "$backend_pid" "$lease_key" "$current_version"
