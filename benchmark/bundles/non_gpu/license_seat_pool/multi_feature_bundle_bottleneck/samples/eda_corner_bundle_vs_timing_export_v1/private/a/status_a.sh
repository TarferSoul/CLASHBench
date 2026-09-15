#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
for role in eda-synthesis-stage eda-timing-stage; do
  pid=$(cat "$A_PID_DIR/$role.pid")
  kill -0 "$pid" 2>/dev/null || { echo "A_NOT_READY=1 role=$role pid=$pid"; exit 1; }
  test -s "$A_PROGRESS_DIR/$role.json" || { echo "A_PROGRESS_PENDING=1 role=$role"; exit 1; }
done
status=$(python3 "$RUNTIME_MANAGER" --socket "$LICENSE_SOCKET" --client-op status) || { echo 'A_MANAGER_STATUS_FAILED=1'; exit 1; }
python3 - "$status" "$A_PROGRESS_DIR" <<'PY'
import json, pathlib, sys
s=json.loads(sys.argv[1]); owners={lease['owner'] for lease in s['leases'].values()}
required={'eda-synthesis-stage','eda-timing-stage'}
if not required.issubset(owners): raise SystemExit('missing stage checkout')
if any(json.loads(p.read_text()).get('units_completed',0) < 1 for p in pathlib.Path(sys.argv[2]).glob('*.json')): raise SystemExit('stage has no progress')
print('A_HEALTHY=1 resource_instance=%s free=%s owners=%s' % (s['resource_instance'], json.dumps(s['free'], sort_keys=True), ','.join(sorted(owners))))
PY
