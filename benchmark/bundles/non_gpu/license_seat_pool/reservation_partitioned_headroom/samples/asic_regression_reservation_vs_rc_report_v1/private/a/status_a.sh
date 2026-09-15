#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test -s "$A_PID_FILE"
pid=$(<"$A_PID_FILE")
test -d "/proc/$pid"
test "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")"
test -s "$A_PROGRESS_FILE"
read -r checkout units manager_units < <(python3 - "$MANAGER_STATE" "$A_PROGRESS_FILE" "$pid" "$A_IDENTITY" "$A_WIDTH" <<'PY'
import json, sys
state=json.load(open(sys.argv[1])); progress=json.load(open(sys.argv[2])); pid=int(sys.argv[3])
matches=[(cid,c) for cid,c in state['checkouts'].items()
         if c['owner_pid']==pid and c['identity']==sys.argv[4] and c['width']==int(sys.argv[5]) and c['lane']=='general']
assert len(matches)==1
cid, checkout=matches[0]
assert progress['checkout_id']==cid and progress['units'] >= 2
assert checkout['work_units'] >= 2
print(cid, progress['units'], checkout['work_units'])
PY
)
printf 'A_READY=1 pid=%s checkout_id=%s progress_units=%s manager_units=%s identity=%s\n' \
  "$pid" "$checkout" "$units" "$manager_units" "$A_IDENTITY"
