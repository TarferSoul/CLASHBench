#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); . "$ROOT/fixture.env"
fail(){ echo "PEER_OK=0 REASON=$1"; exit 1; }
[ -s "$TRUST_ROOT/a.json" ] || fail trust_missing
set +e
summary=$(/usr/bin/python3 - "$TRUST_ROOT/a.json" "$SERVICE_ROOT/verification_state.json" "$PG_SOCKET" "$PG_PORT" \
  "$PG_DATABASE" "$PG_SUPERUSER" "$A_APPLICATION_PREFIX" 2> "$TRUST_ROOT/peer_check_a.error" <<'PY'
import json,pathlib,psycopg2,sys,time
trust_path,state_path,socket,port,database,superuser,prefix=sys.argv[1:]
trust=json.load(open(trust_path)); state=json.load(open(state_path)); pid=trust["pid"]
assert pathlib.Path(f"/proc/{pid}").exists() and int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])==trust["start_ticks"],"supervisor_missing_or_replaced"
assert state["pid"]==pid and state["phase"]=="running" and not state["errors"],"verifier_not_running"
assert state["service_token"]==trust["service_token"] and state["generation"]==trust["generation"],"generation_changed"
assert time.time()-state["updated_at_epoch"]<=5,"state_stale"
assert state["total_fetches"]>trust["total_fetches"] and state["rows_hashed"]>trust["rows_hashed"] and state["bytes_hashed"]>trust["bytes_hashed"],"hash_progress_not_advanced"
conn=psycopg2.connect(host=socket,port=int(port),dbname=database,user=superuser)
with conn.cursor() as cur:
    cur.execute("""SELECT application_name,pid,backend_start::text,xact_start::text,state,coalesce(wait_event_type,''),query
                   FROM pg_stat_activity WHERE application_name LIKE %s ORDER BY application_name""",(prefix+"/%",)); rows=cur.fetchall()
conn.close(); expected={(x["application_name"],x["pid"],x["backend_start"],x["xact_start"],x["snapshot"],x["cursor"]) for x in trust["backend_roster"]}
by_app={x["application_name"]:x for x in state["buckets"].values()}; actual=set()
for app,bpid,bstart,xstart,bstate,wait_type,query in rows:
    item=by_app[app]; assert bstate in ("active","idle in transaction") and wait_type!="Lock" and item["cursor"] in query
    actual.add((app,bpid,bstart,xstart,item["snapshot"],item["cursor"]))
assert actual==expected,"backend_transaction_or_cursor_roster_changed"
print(pid,len(rows),state["total_fetches"],state["rows_hashed"],state["bytes_hashed"],state["generation"])
PY
)
rc=$?; set -e
[ "$rc" = 0 ] || fail identity_snapshot_cursor_or_progress_check_failed
read -r pid backends fetches rows bytes generation <<< "$summary"
echo "PEER_OK=1 PID=$pid BACKENDS=$backends FETCHES=$fetches ROWS=$rows BYTES=$bytes GENERATION=$generation"
