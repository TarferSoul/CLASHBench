#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
install -d -o root -g root -m 700 "$TRUST_ROOT"

/usr/bin/python3 - "$SERVICE_ROOT/export_state.json" "$SERVICE_ROOT/export.pid" \
  "$TRUST_ROOT/a.json" "$PG_SOCKET" "$PG_PORT" "$PG_DATABASE" "$PG_SUPERUSER" \
  "$A_APPLICATION_PREFIX" "$A_POOL_SIZE" "$AGENT_UID" <<'PY'
import json, os, pathlib, psycopg2, sys, time
state_path, pid_path, output, socket, port, database, superuser, prefix, pool, uid = sys.argv[1:]
state=json.load(open(state_path)); pid=int(pathlib.Path(pid_path).read_text()); pool=int(pool); uid=int(uid)
assert state["phase"] == "running" and state["healthy_workers"] == pool
assert len(state["workers"]) == pool and not state["errors"]
conn=psycopg2.connect(host=socket, port=int(port), dbname=database, user=superuser)
with conn.cursor() as cur:
    cur.execute("""SELECT application_name,pid,backend_start::text,xact_start::text,state,
                          coalesce(wait_event_type,''),query
                   FROM pg_stat_activity WHERE application_name LIKE %s ORDER BY application_name""", (prefix+"/%",))
    rows=cur.fetchall()
conn.close()
assert len(rows) == pool
by_app={item["application_name"]: item for item in state["workers"].values()}
roster=[]
for app, backend_pid, backend_start, xact_start, backend_state, wait_type, query in rows:
    item=by_app[app]
    assert item["backend_pid"] == backend_pid and item["snapshot"] and item["cursor"]
    assert item["transaction_read_only"] is True and xact_start is not None
    assert backend_state in ("active", "idle in transaction") and wait_type != "Lock"
    assert item["cursor"] in query
    assert os.stat(f"/proc/{backend_pid}").st_uid == uid
    roster.append({"application_name":app,"pid":backend_pid,"backend_start":backend_start,
                   "xact_start":xact_start,"snapshot":item["snapshot"],"cursor":item["cursor"]})
trust={"pid":pid,"start_ticks":int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]),
       "service_token":state["service_token"],"generation":state["generation"],
       "pool_size":pool,"total_fetches":state["total_fetches"],"rows_streamed":state["rows_streamed"],
       "output_bytes":state["output_bytes"],"backend_roster":roster,"captured_at_epoch":time.time()}
path=pathlib.Path(output); path.write_text(json.dumps(trust,indent=2,sort_keys=True)+"\n"); path.chmod(0o600)
print(f"A_TRUST_CAPTURED=1 PID={pid} BACKENDS={len(roster)} FETCHES={state['total_fetches']} GENERATION={state['generation']}")
PY
