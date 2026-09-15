#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
python3 - "$A_STATE_FILE" "$PG_SOCKET" "$PG_PORT" "$PG_DATABASE" "$PG_ROLE" "$A_PREREQUISITE" <<'PY'
import json,os,pathlib,sys,psycopg2
state_file,socket,port,db,user,version=sys.argv[1:]
def fail(reason,**d): print('A_READY=0 reason='+reason+' '+' '.join(f'{k}={v}' for k,v in d.items())); raise SystemExit(1)
try:
 x=json.load(open(state_file)); pid=int(x['pid']); os.kill(pid,0); st=pathlib.Path(f'/proc/{pid}/stat').read_text().split()
except Exception as e: fail('process_state_unavailable',detail=type(e).__name__)
if st[2] in {'T','t','Z','X'} or int(st[21])!=int(x['process_start_ticks']): fail('process_identity_invalid')
c=psycopg2.connect(host=socket,port=int(port),dbname=db,user=user); q=c.cursor()
q.execute("SELECT state,owner_job_id,owner_backend_pid,plan_digest,current_step,completed_steps,expected_steps,applied_by FROM migration_history WHERE version=%s",(version,)); r=q.fetchone()
if not r or r[0]!='dirty' or r[1]!=x['job_id'] or int(r[2])!=int(x['backend_pid']) or r[7]!='feature-online-reindex' or not(0<=int(r[5])<int(r[6])): fail('dirty_ownership_invalid')
q.execute("SELECT phase,command,relid::regclass::text,index_relid::regclass::text,blocks_total,blocks_done,tuples_total,tuples_done FROM pg_stat_progress_create_index WHERE pid=%s",(r[2],)); p=q.fetchone()
if not p or 'REINDEX CONCURRENTLY' not in p[1]: fail('native_progress_missing',backend=r[2],step=r[4],command=p[1] if p else 'none')
print(f"A_READY=1 pid={pid} job_id={r[1]} backend_pid={r[2]} dirty_state={r[0]} step={r[4]} completed={r[5]}/{r[6]} command={p[1].replace(' ','_')} phase={p[0].replace(' ','_')} blocks={p[5]}/{p[4]} tuples={p[7]}/{p[6]}")
q.close();c.close()
PY
