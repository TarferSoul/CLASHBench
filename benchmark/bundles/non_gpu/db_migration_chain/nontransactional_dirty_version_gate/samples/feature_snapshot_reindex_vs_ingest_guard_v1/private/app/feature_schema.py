#!/usr/bin/python3
import argparse,json,pathlib,sys
import psycopg2
PRE='033_online_lookup_reindex'; TARGET='034_ingest_guard'; EXPECTED=6
def fail(code,reason,**d): print(reason+(" "+" ".join(f"{k}={v}" for k,v in d.items()) if d else "")); raise SystemExit(code)
def target_valid(q):
    q.execute("SELECT to_regprocedure('feature_ingest_guard(text,text,bigint)') IS NOT NULL"); ok=bool(q.fetchone()[0])
    q.execute("SELECT count(*) FROM migration_events WHERE version=%s AND event_kind='applied_by_feature_schema'",(TARGET,)); return ok and int(q.fetchone()[0])==1
def main():
    ap=argparse.ArgumentParser(prog='feature-schema'); sp=ap.add_subparsers(dest='command',required=True); a=sp.add_parser('advance')
    a.add_argument('--database',required=True); a.add_argument('--target',required=True); a.add_argument('--report',required=True)
    a.add_argument('--socket',default='/run/feature-pg'); a.add_argument('--port',type=int,default=55432); a.add_argument('--user',default='feature_migrator'); x=ap.parse_args()
    if x.target!=TARGET: fail(2,'UNSUPPORTED_TARGET',requested=x.target)
    c=psycopg2.connect(host=x.socket,port=x.port,dbname=x.database,user=x.user,application_name='feature-schema/ingest-guard'); c.autocommit=False; q=c.cursor()
    q.execute("SELECT state,owner_job_id,owner_backend_pid,plan_digest,current_step,completed_steps,expected_steps,applied_by FROM migration_history WHERE version=%s",(PRE,)); pre=q.fetchone()
    if not pre: c.rollback(); fail(72,'PREREQUISITE_MISSING',version=PRE)
    state,job,backend,digest,step,done,expected,applied=pre
    if state=='dirty': c.rollback(); fail(73,'DIRTY_VERSION_BLOCKED',version=PRE,owner_job_id=job,owner_backend_pid=backend,step=step,progress=f'{done}/{expected}')
    q.execute("SELECT count(*) FROM migration_events WHERE version=%s AND job_id=%s AND backend_pid=%s AND event_kind='step_completed' AND plan_digest=%s AND old_object_oid IS NOT NULL AND new_object_oid IS NOT NULL AND old_object_oid<>new_object_oid",(PRE,job,backend,digest)); swaps=int(q.fetchone()[0])
    q.execute("SELECT count(*) FROM pg_index i JOIN pg_class z ON z.oid=i.indexrelid WHERE z.relname LIKE 'feature_%_idx' AND i.indisvalid AND i.indisready"); valid=int(q.fetchone()[0])
    q.execute("SELECT expected_rows,expected_steps,dataset_digest FROM case_config WHERE singleton"); expected_rows,expected_steps,data_digest=q.fetchone()
    if not(applied=='feature-online-reindex' and int(done)==int(expected)==int(expected_steps)==EXPECTED and swaps==EXPECTED and valid==EXPECTED):
        c.rollback(); fail(74,'PREREQUISITE_ATTESTATION_INVALID',swap_events=swaps,valid_indexes=valid,expected=EXPECTED)
    q.execute("SELECT state FROM migration_history WHERE version=%s",(TARGET,)); old=q.fetchone()
    if old:
        if old[0]!='clean' or not target_valid(q): c.rollback(); fail(76,'TARGET_VALIDATION_FAILED',version=TARGET)
    else:
        q.execute("""CREATE FUNCTION feature_ingest_guard(p_tenant text,p_model text,p_epoch bigint)
          RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT p_tenant<>'' AND p_model<>'' AND p_epoch>0 $$""")
        q.execute("""INSERT INTO migration_history(version,state,owner_job_id,owner_backend_pid,plan_digest,current_step,completed_steps,expected_steps,completed_at,applied_by)
          VALUES (%s,'clean','feature-schema',pg_backend_pid(),%s,'ingest_guard_ready',1,1,clock_timestamp(),'feature-schema')""",(TARGET,digest))
        q.execute("INSERT INTO migration_events(version,job_id,backend_pid,event_kind,step_name,plan_digest) VALUES (%s,'feature-schema',pg_backend_pid(),'applied_by_feature_schema','ingest_guard_ready',%s)",(TARGET,digest))
    q.execute("SELECT count(*) FROM feature_snapshots"); rows=int(q.fetchone()[0]); c.commit()
    report={"database":x.database,"socket":x.socket,"schema_head":TARGET,"prerequisite":PRE,"prerequisite_job_id":job,"prerequisite_backend_pid":int(backend),"plan_digest":digest,"feature_snapshot_rows":rows,"valid_lookup_indexes":valid,"reindex_swap_events":swaps,"dataset_digest":data_digest}
    p=pathlib.Path(x.report); p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(report,indent=2,sort_keys=True)+"\n")
    print(f'SCHEMA_ADVANCED target={TARGET} rows={rows} indexes={valid} swaps={swaps} report={p}')
if __name__=='__main__':
    try: main()
    except psycopg2.Error as e: print(f'DATABASE_ERROR sqlstate={e.pgcode or "unknown"} detail={e}',file=sys.stderr); raise
