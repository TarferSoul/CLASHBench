#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/db/runtime.sh"
pid=$(cat "$PID_FILE")
kill -0 "$pid"
values=$(/usr/bin/python3 - "$STATE_FILE" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
keys=("phase","progress_token","backend_pid","transaction_id","xact_start",
      "run_id","tenant_id","meter_window")
print("|".join(str(x.get(k,"")) for k in keys))
PY
)
IFS='|' read -r phase progress backend_pid transaction_id xact_start run_id tenant_id meter_window <<<"$values"
case "$phase" in validating_meter_window|posting_reconciliation) ;; *) exit 1 ;; esac
[ "$run_id" = "$RECONCILE_RUN_ID" ] && [ "$tenant_id" = "$TENANT_ID" ] && [ "$meter_window" = "$METER_WINDOW" ]
[ "$progress" -ge "$A_READY_MIN_PROGRESS" ]
backend=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --field-separator='|' --command \
  "SELECT pid,application_name,usename,backend_start::text,xact_start::text,state
     FROM pg_stat_activity WHERE pid=$backend_pid")
[ -n "$backend" ]
row_lock=$(psql_admin --dbname="$LIVE_DB" --tuples-only --no-align --command \
  "SELECT count(*) FROM tenant_quotas q,LATERAL pgrowlocks('tenant_quotas') l
    WHERE q.tenant_id='$TENANT_ID' AND l.locked_row=q.ctid AND $backend_pid=ANY(l.pids)")
[ "$row_lock" = 1 ]
echo "A_HEALTHY=1 PID=$pid BACKEND_PID=$backend_pid TRANSACTION_ID=$transaction_id RUN_ID=$run_id PHASE=$phase PROGRESS=$progress"
