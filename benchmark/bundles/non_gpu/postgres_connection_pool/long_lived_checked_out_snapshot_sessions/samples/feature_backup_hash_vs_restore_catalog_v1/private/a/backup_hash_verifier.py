#!/usr/bin/python3
"""Verify feature snapshot backup buckets through stable hash cursors."""

import hashlib
import json
import os
import pathlib
import signal
import threading
import time

import psycopg2


config=json.loads(pathlib.Path(os.environ["SERVICE_CONFIG"]).read_text())
max_fetches=int(os.environ.get("A_MAX_FETCHES","0"))
stop_event=threading.Event(); lock=threading.Lock(); buckets={}; errors=[]


def save(phase):
    value={"pid":os.getpid(),"phase":phase,"service_token":config["service_token"],"generation":config["generation"],
           "pool_size":config["pool_size"],"healthy_workers":sum(1 for x in buckets.values() if x.get("connected") and not x.get("done")),
           "total_fetches":sum(x.get("fetches",0) for x in buckets.values()),"rows_hashed":sum(x.get("rows",0) for x in buckets.values()),
           "bytes_hashed":sum(x.get("bytes",0) for x in buckets.values()),"buckets":buckets,"errors":list(errors),"updated_at_epoch":time.time()}
    path=pathlib.Path(config["state_path"]); tmp=path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value,indent=2,sort_keys=True)+"\n"); os.replace(tmp,path)


def stop(*_args): stop_event.set()


def verify_bucket(bucket):
    name=f"bucket-{bucket:02d}"; app=f"{config['application_prefix']}/{name}"; cursor_name=f"{config['cursor_prefix']}_{bucket:02d}"
    digest=hashlib.blake2b(digest_size=32); conn=None
    try:
        conn=psycopg2.connect(host=config["socket"],port=config["port"],dbname=config["database"],user=config["role"],application_name=app,connect_timeout=3)
        conn.set_session(readonly=True,isolation_level="REPEATABLE READ",autocommit=False)
        with conn.cursor() as meta:
            meta.execute("SELECT pg_backend_pid(), txid_current_snapshot()::text")
            backend_pid,snapshot=meta.fetchone()
        cursor=conn.cursor(name=cursor_name); cursor.itersize=config["chunk_size"]
        cursor.execute("""SELECT f.feature_id,f.model_family,f.entity_id,f.revision,f.value_checksum,pass_no
                          FROM feature_rows f CROSS JOIN generate_series(1,40) AS pass_no
                          WHERE mod(f.feature_id,%s)=%s ORDER BY pass_no,f.feature_id""",(config["pool_size"],bucket))
        with lock:
            buckets[name]={"application_name":app,"backend_pid":backend_pid,"snapshot":snapshot,"cursor":cursor_name,
                           "transaction_read_only":True,"connected":True,"done":False,"fetches":0,"rows":0,"bytes":0,"digest":digest.hexdigest()}
        while not stop_event.is_set() and not pathlib.Path(config["stop_path"]).exists():
            rows=cursor.fetchmany(config["chunk_size"])
            if not rows: break
            payload="\n".join("|".join(map(str,row)) for row in rows).encode(); digest.update(payload)
            with lock:
                item=buckets[name]; item["fetches"]+=1; item["rows"]+=len(rows); item["bytes"]+=len(payload); item["digest"]=digest.hexdigest()
                reached=max_fetches and item["fetches"]>=max_fetches
            if reached: break
            time.sleep(config["fetch_delay_seconds"])
        cursor.close(); conn.commit()
        with lock: buckets[name]["done"]=True; buckets[name]["connected"]=False
    except Exception as exc:
        with lock: errors.append(f"{name}:{type(exc).__name__}:{exc}"); buckets.setdefault(name,{})["done"]=True
        stop_event.set()
    finally:
        if conn is not None: conn.close()


def main():
    signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)
    threads=[threading.Thread(target=verify_bucket,args=(i,),daemon=True) for i in range(config["pool_size"])]
    for thread in threads: thread.start()
    while any(thread.is_alive() for thread in threads):
        with lock: save("running" if not errors else "failed")
        time.sleep(0.1)
    for thread in threads: thread.join()
    with lock: save("failed" if errors else "complete")
    return 1 if errors else 0


if __name__=="__main__": raise SystemExit(main())
