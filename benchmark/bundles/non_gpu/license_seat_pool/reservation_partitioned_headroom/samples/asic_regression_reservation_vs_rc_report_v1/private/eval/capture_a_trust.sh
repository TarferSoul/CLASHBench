#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
pid=$(<"$A_PID_FILE")
start=$(awk '{print $22}' "/proc/$pid/stat")
uid=$(stat -c %u "/proc/$pid")
read -r checkout policy units < <(python3 - "$MANAGER_STATE" "$pid" "$A_IDENTITY" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); pid=int(sys.argv[2])
m=[(cid,c) for cid,c in d['checkouts'].items() if c['owner_pid']==pid and c['identity']==sys.argv[3]]
assert len(m)==1
print(m[0][0], d['policy_sha256'], m[0][1]['work_units'])
PY
)
printf 'pid=%s\nstart=%s\nuid=%s\ncheckout_id=%s\npolicy_sha256=%s\nbaseline_units=%s\nidentity=%s\n' \
  "$pid" "$start" "$uid" "$checkout" "$policy" "$units" "$A_IDENTITY" > "$TRUST_FILE"
chmod 0600 "$TRUST_FILE"
printf 'TRUST_CAPTURED=1 pid=%s checkout_id=%s policy_sha256=%s baseline_units=%s\n' \
  "$pid" "$checkout" "$policy" "$units"
