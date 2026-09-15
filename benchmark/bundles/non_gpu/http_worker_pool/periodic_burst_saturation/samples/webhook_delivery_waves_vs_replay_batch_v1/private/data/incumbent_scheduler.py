#!/usr/bin/env python3
import argparse, json, os, signal, threading, time, urllib.parse, urllib.request
def call(url):
    with urllib.request.urlopen(url,timeout=8) as r: return json.loads(r.read().decode())
def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--endpoint",required=True); ap.add_argument("--pool",type=int,required=True)
    ap.add_argument("--wave-size",type=int,required=True); ap.add_argument("--duration-ms",type=int,required=True); ap.add_argument("--period-ms",type=int,required=True)
    ap.add_argument("--units",required=True); ap.add_argument("--context",required=True); ap.add_argument("--runtime",required=True); ap.add_argument("--output",required=True)
    a=ap.parse_args(); os.makedirs(a.runtime,exist_ok=True); os.makedirs(a.output,exist_ok=True); stop=threading.Event()
    with open(os.path.join(a.runtime,"scheduler.pid"),"w") as f: json.dump({"pid":os.getpid(),"start_ns":time.time_ns()},f)
    def handler(_sig,_frame): stop.set()
    signal.signal(signal.SIGTERM,handler); signal.signal(signal.SIGINT,handler)
    units=a.units.split(","); wave=0; next_start=time.monotonic()
    while not stop.is_set():
        if next_start>time.monotonic(): stop.wait(next_start-time.monotonic())
        if stop.is_set(): break
        wave+=1; revision=f"{a.context}-revision-{wave:04d}"; batch=f"incumbent-{a.context}-wave-{wave:04d}"
        print(json.dumps({"kind":"wave_start","wave":wave,"batch_id":batch,"revision":revision,"wall_ns":time.time_ns()}),flush=True); results=[None]*a.wave_size
        def one(i):
            q=urllib.parse.urlencode({"owner":"a","request_id":f"a-{a.context}-w{wave:04d}-u{i:02d}","batch_id":batch,"unit":units[i%len(units)],"revision":revision,"duration_ms":a.duration_ms})
            try: results[i]=call(a.endpoint+"?"+q)
            except Exception as exc: results[i]={"ok":False,"error":repr(exc)}
        ts=[threading.Thread(target=one,args=(i,)) for i in range(a.wave_size)]
        [t.start() for t in ts]; [t.join() for t in ts]
        good=[x for x in results if x and x.get("ok") is True]
        if len(good)==a.wave_size:
            record={"wave":wave,"batch_id":batch,"revision":revision,"context":a.context,"request_count":len(good),"receipts":[{"request_id":x["request_id"],"unit":x["unit"],"response_hash":x["response_hash"]} for x in good],"completed_ns":time.time_ns()}
            path=os.path.join(a.output,f"offset_wave_{wave:04d}.json"); tmp=path+".tmp"
            with open(tmp,"w") as f: json.dump(record,f,sort_keys=True)
            os.replace(tmp,path)
            with open(os.path.join(a.output,"state.json.tmp"),"w") as f: json.dump({"last_committed_wave":wave,"last_revision":revision,"committed_offsets":wave*a.wave_size},f)
            os.replace(os.path.join(a.output,"state.json.tmp"),os.path.join(a.output,"state.json"))
            print(json.dumps({"kind":"wave_complete","wave":wave,"batch_id":batch,"revision":revision,"count":len(good),"committed_offsets":wave*a.wave_size,"wall_ns":time.time_ns()}),flush=True)
        else: print(json.dumps({"kind":"wave_failed","wave":wave,"good":len(good),"expected":a.wave_size,"wall_ns":time.time_ns()}),flush=True)
        next_start+=a.period_ms/1000
    print(json.dumps({"kind":"scheduler_stopped","wave":wave,"wall_ns":time.time_ns()}),flush=True)
if __name__=="__main__": main()
