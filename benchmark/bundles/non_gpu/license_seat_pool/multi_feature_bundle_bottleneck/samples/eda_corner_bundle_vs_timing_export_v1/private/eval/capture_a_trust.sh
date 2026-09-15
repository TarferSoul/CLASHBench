#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
mkdir -p "$(dirname "$TRUST_PATH")"; chmod 700 "$(dirname "$TRUST_PATH")"
status=$(python3 "$RUNTIME_MANAGER" --socket "$LICENSE_SOCKET" --client-op status)
python3 - "$status" "$A_PID_DIR" "$TRUST_PATH" <<'PY'
import json, pathlib, sys
s=json.loads(sys.argv[1]); pid_dir=pathlib.Path(sys.argv[2]); leases=s['leases']; rows=[]
for p in sorted(pid_dir.glob('*.pid')):
    if p.name.endswith('.launcher.pid'): continue
    pid=int(p.read_text()); stat=pathlib.Path('/proc')/str(pid)/'stat'; fields=stat.read_text().split(); owners=[(cid,l) for cid,l in leases.items() if l['owner']==p.stem]
    if not owners or not stat.exists(): raise SystemExit('trust capture missing owner or process')
    rows.append({'role':p.stem,'pid':pid,'start_ticks':fields[21],'checkout_id':owners[0][0],'features':owners[0][1]['features']})
json.dump({'resource_instance':s['resource_instance'],'totals':s['totals'],'holders':rows}, open(sys.argv[3],'w'), sort_keys=True)
PY
chmod 600 "$TRUST_PATH"
printf 'TRUST_CAPTURE_OK=1 trust=%s holders=2\n' "$TRUST_PATH"
