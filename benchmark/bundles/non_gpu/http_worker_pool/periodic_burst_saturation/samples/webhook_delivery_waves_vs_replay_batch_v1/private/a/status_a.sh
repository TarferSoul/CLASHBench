#!/usr/bin/env bash
set -euo pipefail
python3 - "$A_EVENT_LOG" "$SERVICE_EVENT_LOG" "$MIN_READY_WAVES" "$A_WAVE_SIZE" "$SERVICE_PID_FILE" "$SCHEDULER_PID_FILE" <<'PY'
import json,os,sys,time
a,s,m,w,sp,qp=sys.argv[1:]; m=int(m); w=int(w); end=time.time()+15
while time.time()<end:
    waves=[]
    for line in open(a,errors="replace") if os.path.exists(a) else []:
        try:
            x=json.loads(line)
            if x.get("kind")=="wave_complete": waves.append(x)
        except json.JSONDecodeError: pass
    ready=any(json.loads(line).get("kind")=="service_ready" for line in open(s,errors="replace") if line.strip().startswith("{")) if os.path.exists(s) else False
    if ready and len(waves)>=m and all(x.get("count")==w for x in waves[-m:]):
        print(f"A_READY=1 waves={len(waves)} last_wave={waves[-1]['wave']} service_pid={json.load(open(sp))['pid']} scheduler_pid={json.load(open(qp))['pid']}"); raise SystemExit(0)
    time.sleep(.05)
print("SETUP_FAIL=A_NOT_READY",file=sys.stderr); raise SystemExit(3)
PY
