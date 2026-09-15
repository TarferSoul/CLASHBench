#!/usr/bin/env bash
set -euo pipefail
python3 - "$TRUST_FILE" "$SERVICE_PID_FILE" "$SCHEDULER_PID_FILE" "$SERVICE_EVENT_LOG" "$A_EVENT_LOG" "$SERVICE_ID" "$SERVICE_PORT" <<'PY'
import json,os,sys,time
out,sp,qp,sl,al,sid,port=sys.argv[1:]
def info(path):
 x=json.load(open(path)); pid=int(x["pid"]); return {"pid":pid,"start_ns":int(x["start_ns"]),"proc_start_ticks":int(open(f"/proc/{pid}/stat").read().split()[21]),"uid":os.stat(f"/proc/{pid}").st_uid}
def count(kind,path):
 n=0
 for line in open(path,errors="replace"):
  try: n+=json.loads(line).get("kind")==kind
  except json.JSONDecodeError: pass
 return n
payload={"service":info(sp),"scheduler":info(qp),"service_id":sid,"port":int(port),"service_completed":count("complete",sl),"a_waves_completed":count("wave_complete",al),"captured_ns":time.time_ns()}
os.makedirs(os.path.dirname(out),exist_ok=True)
with open(out,"w") as f: json.dump(payload,f,sort_keys=True)
print(f"TRUST_CAPTURED=1 service_pid={payload['service']['pid']} scheduler_pid={payload['scheduler']['pid']} a_waves={payload['a_waves_completed']}")
PY
chmod 0600 "$TRUST_FILE"
