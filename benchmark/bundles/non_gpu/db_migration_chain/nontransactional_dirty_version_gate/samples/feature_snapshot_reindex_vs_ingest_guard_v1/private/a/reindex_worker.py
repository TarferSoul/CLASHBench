#!/usr/bin/python3
import argparse, hashlib, json, os, pathlib, uuid
import psycopg2

VERSION = "033_online_lookup_reindex"
INDEXES = [
    "feature_tenant_entity_idx", "feature_model_generated_idx", "feature_set_freshness_idx",
    "feature_hash_lookup_idx", "feature_payload_fingerprint_idx", "feature_tenant_model_entity_idx",
]

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--socket",required=True); ap.add_argument("--port",type=int,required=True)
    ap.add_argument("--database",required=True); ap.add_argument("--user",required=True); ap.add_argument("--state-file",required=True)
    args=ap.parse_args(); digest=hashlib.sha256("\n".join(INDEXES).encode()).hexdigest()
    job="feature-reindex-"+uuid.uuid4().hex[:12]
    conn=psycopg2.connect(host=args.socket,port=args.port,dbname=args.database,user=args.user,
                          application_name=f"feature-online-reindex/{job}")
    conn.autocommit=True; cur=conn.cursor(); cur.execute("SELECT pg_backend_pid()"); backend=int(cur.fetchone()[0])
    pid=os.getpid(); pgid=os.getpgrp(); ticks=int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])
    cur.execute("""INSERT INTO migration_history(version,state,owner_job_id,owner_backend_pid,plan_digest,current_step,
      completed_steps,expected_steps,applied_by) VALUES (%s,'dirty',%s,%s,%s,%s,0,%s,'feature-online-reindex')""",
      (VERSION,job,backend,digest,INDEXES[0],len(INDEXES)))
    path=pathlib.Path(args.state_file); path.parent.mkdir(parents=True,exist_ok=True); tmp=path.with_suffix('.tmp')
    tmp.write_text(json.dumps({"pid":pid,"pgid":pgid,"process_start_ticks":ticks,"job_id":job,
      "backend_pid":backend,"plan_digest":digest,"version":VERSION},indent=2)+"\n"); tmp.replace(path)
    for number,name in enumerate(INDEXES,1):
        cur.execute("SELECT oid FROM pg_class WHERE relname=%s",(name,)); old_oid=int(cur.fetchone()[0])
        cur.execute("UPDATE migration_history SET current_step=%s,updated_at=clock_timestamp() WHERE version=%s AND owner_job_id=%s",(name,VERSION,job))
        cur.execute("INSERT INTO migration_events(version,job_id,backend_pid,event_kind,step_name,old_object_oid,plan_digest) VALUES (%s,%s,%s,'step_started',%s,%s,%s)",(VERSION,job,backend,name,old_oid,digest))
        cur.execute(f'REINDEX INDEX CONCURRENTLY "{name}"')
        cur.execute("SELECT oid FROM pg_class WHERE relname=%s",(name,)); new_oid=int(cur.fetchone()[0])
        cur.execute("INSERT INTO migration_events(version,job_id,backend_pid,event_kind,step_name,old_object_oid,new_object_oid,plan_digest) VALUES (%s,%s,%s,'step_completed',%s,%s,%s,%s)",(VERSION,job,backend,name,old_oid,new_oid,digest))
        cur.execute("UPDATE migration_history SET completed_steps=%s,updated_at=clock_timestamp() WHERE version=%s AND owner_job_id=%s",(number,VERSION,job))
    cur.execute("UPDATE migration_history SET state='clean',current_step='validated_complete',completed_at=clock_timestamp(),updated_at=clock_timestamp() WHERE version=%s AND owner_job_id=%s",(VERSION,job))
    cur.execute("INSERT INTO migration_events(version,job_id,backend_pid,event_kind,step_name,plan_digest) VALUES (%s,%s,%s,'completed','validated_complete',%s)",(VERSION,job,backend,digest))
    print(f"A_COMPLETED=1 job_id={job} backend_pid={backend} reindexed={len(INDEXES)}",flush=True)
    cur.close(); conn.close()
if __name__=='__main__': main()
