#!/usr/bin/python3
"""Build the fixed-width feature restore verification catalog."""

import argparse, json, os, pathlib, sys, threading, time
import psycopg2


def atomic_json(path,value):
    path=pathlib.Path(path); tmp=path.with_suffix(path.suffix+".tmp")
    tmp.write_text(json.dumps(value,indent=2,sort_keys=True)+"\n"); os.replace(tmp,path)


def capacity_error(exc):
    message=str(exc).strip(); sqlstate=getattr(exc,"pgcode",None)
    if sqlstate is None and ("remaining connection slots are reserved" in message or "too many clients already" in message): sqlstate="53300"
    return sqlstate,message


def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--plan",required=True); parser.add_argument("--output",required=True); args=parser.parse_args()
    plan=json.loads(pathlib.Path(args.plan).read_text()); required=int(plan["required_sessions"]); families=list(plan["families"])
    if required!=5 or len(families)!=required: raise SystemExit("the restore catalog requires exactly five concurrent sessions")
    output=pathlib.Path(args.output); output.mkdir(parents=True,exist_ok=True)
    for old in output.glob("*.json"): old.unlink()
    barrier=threading.Barrier(required); start=threading.Event(); lock=threading.Lock(); connected=0; peak=0; results=[]; failures=[]
    def worker(family):
        nonlocal connected,peak
        conn=None; start.wait()
        try:
            conn=psycopg2.connect(host=plan["socket"],port=plan["port"],dbname=plan["database"],user=plan["role"],
                                  application_name=f"{plan['application_prefix']}/{family}",connect_timeout=3)
            conn.set_session(readonly=True,isolation_level="REPEATABLE READ",autocommit=False)
            with lock: connected+=1; peak=max(peak,connected)
            try: barrier.wait(timeout=5)
            except threading.BrokenBarrierError as exc: raise RuntimeError("required five-snapshot cohort did not form") from exc
            with conn.cursor() as cur:
                cur.execute("SELECT pg_backend_pid(),txid_current_snapshot()::text,current_setting('transaction_read_only')")
                backend_pid,snapshot,read_only=cur.fetchone()
                cur.execute("""SELECT count(*)::bigint,count(DISTINCT entity_id)::bigint,min(revision)::int,max(revision)::int,
                                      md5(string_agg(feature_id::text || ':' || value_checksum,',' ORDER BY feature_id))
                               FROM feature_rows WHERE model_family=%s""",(family,))
                row_count,entities,min_revision,max_revision,digest=cur.fetchone(); time.sleep(float(plan["hold_seconds"]))
            conn.commit()
            record={"catalog_id":plan["catalog_id"],"family":family,"status":"verified","database":plan["database"],"role":plan["role"],
                    "backend_pid":backend_pid,"snapshot":snapshot,"transaction_read_only":read_only=="on","row_count":row_count,
                    "distinct_entities":entities,"min_revision":min_revision,"max_revision":max_revision,"digest":digest}
            atomic_json(output/f"family_{family}.json",record)
            with lock: results.append(record)
        except Exception as exc:
            barrier.abort(); sqlstate,message=capacity_error(exc)
            with lock: failures.append({"family":family,"error_type":type(exc).__name__,"sqlstate":sqlstate,"message":message})
        finally:
            if conn is not None:
                conn.close()
                with lock: connected-=1
    threads=[threading.Thread(target=worker,args=(family,),daemon=True) for family in families]
    for thread in threads: thread.start()
    start.set()
    for thread in threads: thread.join(timeout=12)
    if any(thread.is_alive() for thread in threads): barrier.abort(); failures.append({"family":"cohort","error_type":"Timeout","sqlstate":None,"message":"worker did not finish"})
    atomic_json(output/"attempt.json",{"catalog_id":plan["catalog_id"],"required_sessions":required,"peak_sessions":peak,
                                       "completed_families":sorted(x["family"] for x in results),"failure_count":len(failures),"failures":failures})
    if failures or len(results)!=required or peak!=required:
        print(f"COHORT_ERROR required={required} peak={peak} completed={len(results)} failures={len(failures)}",file=sys.stderr); return 12
    catalog={"catalog_id":plan["catalog_id"],"status":"verified","database":plan["database"],"role":plan["role"],"socket":plan["socket"],
             "port":plan["port"],"required_sessions":required,"peak_sessions":peak,"backend_pids":sorted(x["backend_pid"] for x in results),
             "families":sorted(families),"snapshots":sorted(x["snapshot"] for x in results)}
    atomic_json(output/"catalog.json",catalog)
    print(f"RESTORE_CATALOG_COMPLETE catalog_id={plan['catalog_id']} sessions={required} families={','.join(sorted(families))}"); return 0


if __name__=="__main__": raise SystemExit(main())
