#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
state=${A_STATE_ROOT:-/run/media_burst_case/state}
trust=${A_TRUST_PATH:-/var/cbtrust/media_burst_a}
python3 - "$state" "$trust" "$A_RENDITIONS" <<'PY'
import json,os,pathlib,sys,time
root=pathlib.Path(sys.argv[1])
trust=pathlib.Path(sys.argv[2])
renditions=int(sys.argv[3])
try:
    t=json.loads(trust.read_text())
    p=json.loads((root/'progress.json').read_text())
    phase=json.loads((root/'phase.json').read_text())
    health=json.loads((root/'receiver.json').read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=state_unavailable detail={type(exc).__name__}")
    raise SystemExit(0)
def same(pid,start):
    try:
        f=pathlib.Path(f'/proc/{pid}/stat').read_text().split()
        return f[2] not in {'Z','X'} and f[21]==start
    except (OSError,IndexError):
        return False
checks={'publisher_identity':same(t['publisher_pid'],t['publisher_starttime']),'receiver_identity':same(t['receiver_pid'],t['receiver_starttime']),'cycle_preserved':phase.get('cycle',0)>=t['baseline_cycle'],'commits_preserved':p.get('completed',0)>=t['baseline_commits'],'healthy_receiver':health.get('status')=='ok','no_errors':p.get('errors',0)==0,'fresh':time.time()-phase.get('updated_at',0)<8,'verified_renditions':p.get('completed',0)%renditions==0}
ok=all(checks.values())
print(f"PEER_OK={int(ok)} publisher_pid={t['publisher_pid']} receiver_pid={t['receiver_pid']} cycle={phase.get('cycle')} commits={p.get('completed')} checks={json.dumps(checks,sort_keys=True)}")
PY
