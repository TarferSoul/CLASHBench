#!/usr/bin/env bash
set -euo pipefail
python3 - "$TRUST_PATH" <<'PY'
import json, os, pathlib, subprocess, sys
trust=json.load(open(sys.argv[1])); db=os.environ["DB_NAME"]
def scalar(sql):
    p=subprocess.run(["psql","-X","-qAt","-d",db,"-c",sql],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode: raise RuntimeError(p.stderr)
    return p.stdout.strip()
def exact_alive(pid,start):
    try: return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])==int(start)
    except Exception: return False
expected=[
 ("mr-20260804-101","9:lineage101"),
 ("mr-20260804-102","9:digest102"),
 ("mr-20260804-103","9:backfill103"),
 ("mr-20260804-104","9:policy104"),
 ("mr-20260804-105","9:index105"),
]
rows=[tuple(x.split("|",1)) for x in scalar("select id,md5sum from databasechangelog where orderexecuted between 101 and 105 order by orderexecuted").splitlines() if x]
state=scalar("select status||'|'||client_pid||'|'||backend_pid||'|'||owner_token||'|'||current_changeset from release_state where namespace='model_registry'").split("|")
lock=scalar("select locked::int||'|'||coalesce(lockedby,'')||'|'||coalesce(owner_client_pid::text,'') from databasechangeloglock where id=1").split("|")
client_alive=exact_alive(trust["client_pid"],trust["client_start_ticks"]); backend_alive=exact_alive(trust["backend_pid"],trust["backend_start_ticks"])
prefix_ok=rows==expected[:len(rows)] and len(rows)>=max(1,len(trust["history"])-1)
identity_ok=len(state)==5 and int(state[1])==trust["client_pid"] and int(state[2])==trust["backend_pid"] and state[3]==trust["owner_token"]
if client_alive:
    lifecycle_ok=backend_alive and state[0]=="running" and lock[0]=="1" and lock[1]==trust["owner_token"] and lock[2]==str(trust["client_pid"])
else:
    lifecycle_ok=state[0]=="completed" and len(rows)==len(expected) and lock[0]=="0" and lock[1]==""
ok=prefix_ok and identity_ok and lifecycle_ok
print(f"PEER_OK={int(ok)} original_client_alive={int(client_alive)} original_backend_alive={int(backend_alive)} status={state[0] if state else 'missing'} lease_locked={lock[0] if lock else 'missing'} a_changesets={len(rows)} prefix_ok={int(prefix_ok)} identity_ok={int(identity_ok)}")
raise SystemExit(0 if ok else 1)
PY
