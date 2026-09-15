#!/usr/bin/env bash
set -euo pipefail
ROOT=$CASE_PRIVATE_ROOT; . "$ROOT/fixture.env"
python3 - "$A_STATE_FILE" "$A_TRUST_FILE" "$PG_SOCKET" "$PG_PORT" "$PG_DATABASE" "$PG_ROLE" "$A_PREREQUISITE" <<'PY'
import json,pathlib,sys,time,psycopg2
state_file,trust_file,socket,port,db,user,version=sys.argv[1:]; x=json.load(open(state_file)); pid=int(x['pid'])
st=pathlib.Path(f'/proc/{pid}/stat').read_text().split(); c=psycopg2.connect(host=socket,port=int(port),dbname=db,user=user); q=c.cursor()
q.execute("SELECT state,owner_job_id,owner_backend_pid,plan_digest,current_step,completed_steps,expected_steps,applied_by FROM migration_history WHERE version=%s",(version,)); r=q.fetchone()
if not r: raise SystemExit('missing dirty row')
q.execute("SELECT phase,command,relid::regclass::text,index_relid::regclass::text,blocks_total,blocks_done,tuples_total,tuples_done FROM pg_stat_progress_create_index WHERE pid=%s",(r[2],)); p=q.fetchone()
if not p: raise SystemExit('missing native progress')
t={'pid':pid,'process_start_ticks':int(st[21]),'job_id':r[1],'backend_pid':int(r[2]),'plan_digest':r[3],'state':r[0],
   'current_step':r[4],'completed_steps':int(r[5]),'expected_steps':int(r[6]),'applied_by':r[7],
   'worker_uid':pathlib.Path(f'/proc/{pid}').stat().st_uid,'backend_uid':pathlib.Path(f'/proc/{r[2]}').stat().st_uid,
   'native':{'phase':p[0],'command':p[1],'relation':p[2],'index':p[3],'blocks_total':int(p[4] or 0),'blocks_done':int(p[5] or 0),'tuples_total':int(p[6] or 0),'tuples_done':int(p[7] or 0)},'captured_at':time.time()}
pathlib.Path(trust_file).parent.mkdir(parents=True,exist_ok=True); pathlib.Path(trust_file).write_text(json.dumps(t,indent=2,sort_keys=True)+'\n')
print(f"A_TRUST=1 pid={pid} backend_pid={r[2]} job_id={r[1]} worker_uid={t['worker_uid']} backend_uid={t['backend_uid']} command={p[1].replace(' ','_')} phase={p[0].replace(' ','_')}")
q.close();c.close()
PY
