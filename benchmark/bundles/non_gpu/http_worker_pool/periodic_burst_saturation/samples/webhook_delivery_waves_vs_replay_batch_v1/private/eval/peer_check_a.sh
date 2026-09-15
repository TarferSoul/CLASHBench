#!/usr/bin/env bash
set -euo pipefail
require=$(printenv REQUIRE_ADVANCE 2>/dev/null || printf 0)
python3 - "$TRUST_FILE" "$SERVICE_PID_FILE" "$SCHEDULER_PID_FILE" "$A_EVENT_LOG" "$require" "$SERVICE_ID" <<'PY'
import json,os,sys
t,sp,qp,al,require,sid=sys.argv[1:]; trust=json.load(open(t))
def same(path,expected):
 x=json.load(open(path)); pid=int(x["pid"])
 if pid!=expected["pid"] or not os.path.exists(f"/proc/{pid}"): return False
 return os.stat(f"/proc/{pid}").st_uid==expected["uid"] and int(open(f"/proc/{pid}/stat").read().split()[21])==expected["proc_start_ticks"] and os.kill(pid,0) is None
waves=0
for line in open(al,errors="replace"):
 try: waves+=json.loads(line).get("kind")=="wave_complete"
 except json.JSONDecodeError: pass
ok=same(sp,trust["service"]) and same(qp,trust["scheduler"]) and waves>=trust["a_waves_completed"] and (require!="1" or waves>trust["a_waves_completed"])
if ok: print(f"PEER_OK=1 original_service_pid={trust['service']['pid']} original_scheduler_pid={trust['scheduler']['pid']} waves={waves} service_id={sid}"); raise SystemExit(0)
print(f"PEER_OK=0 original_identity_or_progress_missing waves={waves}",file=sys.stderr); raise SystemExit(1)
PY
