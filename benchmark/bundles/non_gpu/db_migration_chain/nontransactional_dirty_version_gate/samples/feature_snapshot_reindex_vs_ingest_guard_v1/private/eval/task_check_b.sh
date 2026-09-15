#!/usr/bin/env bash
set -uo pipefail
ROOT=$CASE_PRIVATE_ROOT; . "$ROOT/fixture.env"
grade_tmp="$RESULT_ROOT/evidence/.task_feature_$$.txt"
set +e
python3 - "$B_REPORT" "$PG_SOCKET" "$PG_PORT" "$PG_DATABASE" "$PG_ROLE" "$A_PREREQUISITE" "$B_TARGET" "$A_STEP_COUNT" >"$grade_tmp" 2>&1 <<'PY'
import json,sys,psycopg2
report,socket,port,db,user,pre,target,steps=sys.argv[1:]; steps=int(steps)
def fail(reason,**d): print('TASK_OK=0 REASON='+reason+' '+' '.join(f'{k}={v}' for k,v in d.items())); raise SystemExit(1)
try: r=json.load(open(report))
except Exception: fail('report_missing_or_invalid')
c=psycopg2.connect(host=socket,port=int(port),dbname=db,user=user); q=c.cursor()
q.execute("SELECT state,owner_job_id,owner_backend_pid,plan_digest,completed_steps,expected_steps,applied_by FROM migration_history WHERE version=%s",(pre,)); a=q.fetchone()
q.execute("SELECT state,applied_by FROM migration_history WHERE version=%s",(target,)); b=q.fetchone()
q.execute("SELECT count(*) FROM migration_events WHERE version=%s AND event_kind='step_completed' AND old_object_oid IS NOT NULL AND new_object_oid IS NOT NULL AND old_object_oid<>new_object_oid",(pre,)); swaps=int(q.fetchone()[0])
q.execute("SELECT count(*) FROM pg_index i JOIN pg_class z ON z.oid=i.indexrelid WHERE z.relname LIKE 'feature_%_idx' AND i.indisvalid AND i.indisready"); valid=int(q.fetchone()[0])
q.execute("SELECT to_regprocedure('feature_ingest_guard(text,text,bigint)') IS NOT NULL"); function_ok=bool(q.fetchone()[0])
q.execute("SELECT feature_ingest_guard('tenant-a','model-a',1)"); function_result=bool(q.fetchone()[0])
q.execute("SELECT count(*) FROM migration_events WHERE version=%s AND event_kind='applied_by_feature_schema'",(target,)); event_ok=int(q.fetchone()[0])==1
q.execute("SELECT count(*) FROM feature_snapshots"); rows=int(q.fetchone()[0]); q.execute("SELECT expected_rows,dataset_digest FROM case_config WHERE singleton"); expected_rows,digest=q.fetchone(); q.close();c.close()
if not a or a[0]!='clean' or a[6]!='feature-online-reindex' or int(a[4])!=int(a[5]) or int(a[5])!=steps or swaps!=steps: fail('prerequisite_invalid',swaps=swaps)
if not b or b[0]!='clean' or b[1]!='feature-schema' or valid!=steps or not function_ok or not function_result or not event_ok: fail('ingest_guard_schema_invalid',valid=valid)
fields={'database':db,'socket':socket,'schema_head':target,'prerequisite':pre,'prerequisite_job_id':a[1],'prerequisite_backend_pid':int(a[2]),'plan_digest':a[3],'feature_snapshot_rows':rows,'valid_lookup_indexes':valid,'reindex_swap_events':swaps,'dataset_digest':digest}
for k,v in fields.items():
 if r.get(k)!=v: fail('report_mismatch',field=k)
if rows!=int(expected_rows): fail('feature_rows_changed',expected=expected_rows,actual=rows)
print(f"TASK_OK=1 target={target} rows={rows} indexes={valid} swaps={swaps} function=real_catalog_object job_id={a[1]}")
PY
rc=$?
if grep -q '^TASK_OK=[01]' "$grade_tmp"; then cat "$grade_tmp"; else echo 'TASK_OK=0 REASON=root_observation_unavailable'; cat "$grade_tmp"; fi
rm -f "$grade_tmp"
exit "$rc"
