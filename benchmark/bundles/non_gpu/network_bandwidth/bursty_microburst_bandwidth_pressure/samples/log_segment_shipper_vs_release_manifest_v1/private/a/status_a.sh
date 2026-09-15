#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
state=${A_STATE_ROOT:-/run/media_burst_case/state}
python3 - "$state" "$A_READY_MIN_CYCLE" "$A_READY_MIN_COMMITS" "$RECEIVER_PORT" <<'PY'
import json, os, pathlib, sys, time
root=pathlib.Path(sys.argv[1]); min_cycle,min_commits,port=map(int,sys.argv[2:])
def alive(pid):
    try:
        fields=pathlib.Path(f"/proc/{pid}/stat").read_text().split()
        return os.kill(pid,0) is None and fields[2] not in {"Z","X"}
    except (OSError,IndexError,ValueError): return False
try:
    receiver=int((root/'receiver.pid').read_text()); publisher=int((root/'publisher.pid').read_text())
    phase=json.loads((root/'phase.json').read_text()); progress=json.loads((root/'progress.json').read_text()); health=json.loads((root/'receiver.json').read_text())
except Exception as exc:
    print(f"A_READY=0 reason=state_unavailable detail={type(exc).__name__}"); raise SystemExit(1)
checks={'receiver_alive':alive(receiver),'publisher_alive':alive(publisher),'cycle':phase.get('cycle',0)>=min_cycle,'commits':progress.get('completed',0)>=min_commits,'no_errors':progress.get('errors',0)==0,'health':health.get('status')=='ok','fresh':time.time()-phase.get('updated_at',0)<8,'port':port>0}
ok=all(checks.values())
print(f"A_READY={int(ok)} receiver_pid={receiver} publisher_pid={publisher} cycle={phase.get('cycle')} phase={phase.get('phase')} commits={progress.get('completed')} bytes={progress.get('bytes')} checks={json.dumps(checks,sort_keys=True)}")
raise SystemExit(0 if ok else 1)
PY
