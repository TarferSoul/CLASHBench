#!/usr/bin/env python3
import argparse, concurrent.futures, hashlib, json, time, urllib.parse, urllib.request
def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--request",required=True); ap.add_argument("--receipts",required=True); ap.add_argument("--summary",required=True)
    a=ap.parse_args(); spec=json.load(open(a.request)); started=time.time_ns()
    def one(pair):
        i,event=pair; rid=f"b-webhook-replay-{spec['batch_id']}-{i:03d}"
        q=urllib.parse.urlencode({"owner":"b","request_id":rid,"batch_id":spec["batch_id"],"unit":event,"revision":spec["revision"],"duration_ms":spec["request_duration_ms"]})
        try:
            with urllib.request.urlopen(spec["endpoint"]+"?"+q,timeout=12) as r: body=json.loads(r.read().decode())
            return {"index":i,"event_id":event,"status":200,"body":body}
        except Exception as exc: return {"index":i,"event_id":event,"status":0,"error":repr(exc)}
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: rows=list(pool.map(one,enumerate(spec["events"])))
    rows.sort(key=lambda x:x["index"]); finished=time.time_ns()
    with open(a.receipts,"w") as f:
        for row in rows: f.write(json.dumps(row,sort_keys=True)+"\n")
    digest=hashlib.sha256(open(a.receipts,"rb").read()).hexdigest()
    ok=all(x.get("status")==200 and x.get("body",{}).get("ok") is True for x in rows)
    summary={"batch_id":spec["batch_id"],"revision":spec["revision"],"event_count":len(rows),"acknowledged_count":sum(x.get("status")==200 for x in rows),"started_ns":started,"finished_ns":finished,"elapsed_ms":round((finished-started)/1e6,3),"delivery_lease_ms":spec["delivery_lease_ms"],"lease_ok":bool(ok and (finished-started)/1e6<=spec["delivery_lease_ms"]),"receipt_ledger_sha256":digest}
    with open(a.summary,"w") as f: json.dump(summary,f,indent=2,sort_keys=True)
    print(json.dumps({"receipts":a.receipts,"summary":a.summary,"lease_ok":summary["lease_ok"],"elapsed_ms":summary["elapsed_ms"],"event_count":len(rows)},sort_keys=True))
    raise SystemExit(0 if ok else 1)
if __name__=="__main__": main()
