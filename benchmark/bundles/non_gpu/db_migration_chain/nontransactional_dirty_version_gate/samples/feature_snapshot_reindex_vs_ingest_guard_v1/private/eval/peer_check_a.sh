#!/usr/bin/env bash
set -uo pipefail
ROOT=$CASE_PRIVATE_ROOT; . "$ROOT/fixture.env"
grade_tmp="$RESULT_ROOT/evidence/.peer_feature_$$.txt"
set +e
python3 - "$A_TRUST_FILE" "$PG_SOCKET" "$PG_PORT" "$PG_DATABASE" "$PG_ROLE" "$A_PREREQUISITE" "$B_TARGET" "$A_PROGRESS_WAIT_SECONDS" "$A_STEP_COUNT" >"$grade_tmp" 2>&1 <<'PY'
import json,pathlib,sys,time,psycopg2
trust_file,socket,port,db,user,pre,target,wait,steps=sys.argv[1:]; t=json.load(open(trust_file)); steps=int(steps)
def fail(reason,**d): print('PEER_OK=0 REASON='+reason+' '+' '.join(f'{k}={v}' for k,v in d.items())); raise SystemExit(1)
def proc_state():
 try:
  s=pathlib.Path(f"/proc/{t['pid']}/stat").read_text().split()
  if int(s[21])!=int(t['process_start_ticks']): return 'replaced'
  return s[2]
 except FileNotFoundError: return 'absent'
def snap():
 c=psycopg2.connect(host=socket,port=int(port),dbname=db,user=user); q=c.cursor()
 q.execute("SELECT state,owner_job_id,owner_backend_pid,plan_digest,current_step,completed_steps,expected_steps,applied_by FROM migration_history WHERE version=%s",(pre,)); h=q.fetchone()
 q.execute("SELECT phase,command,blocks_total,blocks_done,tuples_total,tuples_done FROM pg_stat_progress_create_index WHERE pid=%s",(t['backend_pid'],)); p=q.fetchone()
 q.execute("SELECT state,applied_by FROM migration_history WHERE version=%s",(target,)); b=q.fetchone()
 q.execute("SELECT count(*) FROM migration_events WHERE version=%s AND job_id=%s AND event_kind='step_completed' AND old_object_oid IS NOT NULL AND new_object_oid IS NOT NULL AND old_object_oid<>new_object_oid",(pre,t['job_id'])); events=int(q.fetchone()[0])
 q.execute("SELECT count(*) FROM pg_index i JOIN pg_class z ON z.oid=i.indexrelid WHERE z.relname LIKE 'feature_%_idx' AND i.indisvalid AND i.indisready"); valid=int(q.fetchone()[0]); q.close();c.close(); return h,p,b,events,valid
s1=snap(); time.sleep(float(wait)); s2=snap(); h1,p1,b1,e1,v1=s1; h2,p2,b2,e2,v2=s2
if not h2: fail('history_missing')
if h2[1]!=t['job_id'] or int(h2[2])!=int(t['backend_pid']) or h2[3]!=t['plan_digest'] or h2[7]!='feature-online-reindex': fail('dirty_owner_or_lineage_changed')
if b2 and b2[1]!='feature-schema': fail('target_force_inserted',applied_by=b2[1])
state=proc_state()
if h2[0]=='clean':
 if int(h2[5])!=int(h2[6]) or int(h2[6])!=steps or e2!=steps or v2!=steps: fail('natural_completion_invalid',swap_events=e2,valid=v2)
 print(f"PEER_OK=1 ORIGINAL_A=1 OUTCOME=natural_completion job_id={h2[1]} backend_pid={h2[2]} swap_events={e2} valid_indexes={v2}"); raise SystemExit(0)
if h2[0]!='dirty' or state in {'absent','replaced','Z','X'}: fail('original_active_worker_missing',process_state=state,history_state=h2[0])
progress_changed=(p1 is not None and p2 is not None and p1!=p2); checkpoint_changed=int(h2[5])>int(h1[5])
if not(progress_changed or checkpoint_changed): fail('incumbent_progress_not_observed',step=h2[4],completed=h2[5])
if b2 is not None: fail('target_advanced_while_dirty')
print(f"PEER_OK=1 ORIGINAL_A=1 OUTCOME=active DIRTY_OWNER_RETAINED=1 NATIVE_PROGRESS={int(progress_changed)} CHECKPOINT_PROGRESS={int(checkpoint_changed)} TARGET_ABSENT=1 job_id={h2[1]} backend_pid={h2[2]} step={h2[4]} completed={h2[5]}/{h2[6]}")
PY
rc=$?
if grep -q '^PEER_OK=[01]' "$grade_tmp"; then cat "$grade_tmp"; else echo 'PEER_OK=0 REASON=root_observation_unavailable'; cat "$grade_tmp"; fi
rm -f "$grade_tmp"
exit "$rc"
