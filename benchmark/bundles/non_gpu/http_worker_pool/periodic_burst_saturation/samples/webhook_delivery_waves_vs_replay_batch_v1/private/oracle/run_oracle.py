#!/usr/bin/env python3
import json, os, pathlib, shutil, subprocess, time
def items(path):
 out=[]
 if not os.path.exists(path): return out
 for line in open(path,errors="replace"):
  try: out.append(json.loads(line))
  except json.JSONDecodeError: pass
 return out
def run(cmd,timeout=30): return subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout,check=False)
def wait_for(fn,timeout,msg):
 end=time.time()+timeout
 while time.time()<end:
  if fn(): return
  time.sleep(.05)
 raise RuntimeError(msg)
def main():
 env=os.environ; service_log=env["SERVICE_EVENT_LOG"]; a_log=env["A_EVENT_LOG"]; client=os.path.join(env["INSTALL_ROOT"],env["B_CLIENT_FILE"]); request=env["B_REQUEST_RUNTIME"]
 start=os.path.join(env["PRIVATE_CASE"],"a","start_a.sh"); stop=os.path.join(env["PRIVATE_CASE"],"a","stop_a.sh"); status=os.path.join(env["PRIVATE_CASE"],"a","status_a.sh"); capture=os.path.join(env["PRIVATE_CASE"],"eval","capture_a_trust.sh")
 root=pathlib.Path("/run")/("http_pool_oracle_"+env["SAMPLE_ID"]); shutil.rmtree(root,ignore_errors=True); root.mkdir(mode=0o700); (root/"probes").mkdir(mode=0o700)
 def bprobe(name):
  receipts=root/"probes"/(name+"_receipts.jsonl"); summary=root/"probes"/(name+"_summary.json")
  out=run([client,"--request",request,"--receipts",str(receipts),"--summary",str(summary)],timeout=25)
  if not receipts.exists() or not summary.exists(): raise RuntimeError(f"probe {name} missing output {out.stderr[-300:]}")
  return json.load(open(summary)), receipts
 started_service=run(["bash",start,"service"],timeout=10)
 if started_service.returncode: raise RuntimeError("service start failed: "+started_service.stderr[-500:])
 for i in range(3): bprobe("baseline_"+str(i))
 started_scheduler=run(["bash",start,"scheduler"],timeout=10)
 if started_scheduler.returncode: raise RuntimeError("scheduler start failed: "+started_scheduler.stderr[-500:])
 ready=run(["bash",status],timeout=20)
 if ready.returncode: raise RuntimeError("A status failed: "+ready.stderr[-500:])
 cap=run(["bash",capture],timeout=10)
 if cap.returncode: raise RuntimeError("trust capture failed")
 trust=json.load(open(env["TRUST_FILE"])); previous=max(x["wave"] for x in items(a_log) if x.get("kind")=="wave_start"); observations=[]
 for i in range(2):
  def ready():
   starts=[x for x in items(a_log) if x.get("kind")=="wave_start" and x.get("wave",0)>previous]
   if not starts: return False
   wave=starts[0]["wave"]; batch=f"incumbent-webhook-wave-{wave:04d}"
   return len([x for x in items(service_log) if x.get("kind")=="dispatch" and x.get("batch_id")==batch and x.get("owner")=="a"])>=int(env["POOL_SIZE"])
  wait_for(ready,12,"A full webhook wave was not observed")
  wave=min(x["wave"] for x in items(a_log) if x.get("kind")=="wave_start" and x.get("wave",0)>previous); previous=wave
  started=time.time_ns(); summary,receipts=bprobe("with_a_"+str(i)); finished=time.time_ns()
  observations.append({"probe":i,"wave":wave,"started_ns":started,"finished_ns":finished,"summary":summary,"receipts":str(receipts)})
 wait_for(lambda:len([x for x in items(a_log) if x.get("kind")=="wave_complete"])>trust["a_waves_completed"],12,"later A wave did not complete")
 run(["bash",stop,"scheduler"],timeout=15)
 wait_for(lambda:any(x.get("kind")=="metric" and x.get("active")==0 and x.get("queued")==0 for x in items(service_log)[-20:]),8,"pool did not drain")
 for i in range(3): bprobe("recovery_"+str(i))
 base=[json.load(open(root/"probes"/("baseline_"+str(i)+"_summary.json"))) for i in range(3)]
 rec=[json.load(open(root/"probes"/("recovery_"+str(i)+"_summary.json"))) for i in range(3)]
 ev=items(service_log)
 for o in observations:
  ids={f"b-webhook-replay-{json.load(open(request))['batch_id']}-{i:03d}" for i in range(8)}
  ds=[x for x in ev if x.get("kind")=="dispatch" and x.get("owner")=="b" and x.get("batch_id")==json.load(open(request))["batch_id"] and x.get("request_id") in ids and o["started_ns"]<=x.get("wall_ns",0)<=o["finished_ns"]]
  ms=[x for x in ev if x.get("kind")=="metric" and o["started_ns"]<=x.get("wall_ns",0)<=o["finished_ns"]]
  o["max_active"]=max((x.get("active",0) for x in ms),default=0); o["max_queued"]=max((x.get("queued",0) for x in ms),default=0)
  o["b_dispatches"]=len(ds); o["max_queue_wait_ms"]=max((x.get("queue_wait_ms",0) for x in ds),default=0)
  first=min((x.get("wall_ns",0) for x in ds),default=10**30); o["a_dispatch_before_b"]=any(x.get("kind")=="dispatch" and x.get("owner")=="a" and x.get("wall_ns",0)<first for x in ev)
 summary={"baseline_lease_ok":[x.get("lease_ok") for x in base],"recovery_lease_ok":[x.get("lease_ok") for x in rec],"observations":observations,"a_original":trust,"service_pid":trust["service"]["pid"],"event_count":len(ev)}
 json.dump(summary,open(root/"oracle_summary.json","w"),indent=2,sort_keys=True); shutil.copytree(root,pathlib.Path(env["RESULT_ROOT"])/"evidence"/"oracle_private_evidence",dirs_exist_ok=True)
 good=all(x.get("lease_ok") is True for x in base+rec); blocked=all(x["summary"].get("lease_ok") is False and x["max_active"]==int(env["POOL_SIZE"]) and x["max_queued"]>0 and x["b_dispatches"]==8 and x["a_dispatch_before_b"] for x in observations)
 if good and blocked:
  print("CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=http_worker_pool REASON=phase_aligned_webhook_waves_fill_all_workers_and_recovery_is_observed"); return 0
 print(f"CONFLICT_OK=0 baseline={good} baseline_values={summary['baseline_lease_ok']} recovery_values={summary['recovery_lease_ok']} blocked={blocked} observations={json.dumps(observations,sort_keys=True)}"); return 1
if __name__=="__main__":
 try: raise SystemExit(main())
 except Exception as exc: print(f"CONFLICT_OK=0 oracle_error={exc}"); raise SystemExit(1)
