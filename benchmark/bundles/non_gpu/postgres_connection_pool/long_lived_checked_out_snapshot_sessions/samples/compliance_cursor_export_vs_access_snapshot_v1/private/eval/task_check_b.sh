#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
OUTPUT=${1:-$B_OUTPUT}
OBSERVER=${2:?observer evidence required}

set +e
summary=$(/usr/bin/python3 - "$B_PLAN" "$OUTPUT" "$OBSERVER" "$PG_SUPERUSER" 2> "$TRUST_ROOT/task_check_b.error" <<'PY'
import json, pathlib, psycopg2, sys
plan=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2]); observed=json.load(open(sys.argv[3])); superuser=sys.argv[4]
manifest=json.load(open(root/"manifest.json"))
assert manifest["report_id"]==plan["report_id"] and manifest["status"]=="complete"
assert manifest["database"]==plan["database"] and manifest["role"]==plan["role"]
assert manifest["socket"]==plan["socket"] and manifest["port"]==plan["port"]
assert manifest["required_sessions"]==manifest["peak_sessions"]==plan["required_sessions"]==4
assert manifest["teams"]==sorted(plan["teams"]) and len(set(manifest["backend_pids"]))==4
assert observed["error"] is None and observed["database"]==plan["database"] and observed["role"]==plan["role"]
assert observed["full_cohort_observed"] is True and observed["peak_transactional_sessions"] >= 4
assert set(manifest["backend_pids"]).issubset(set(observed["observed_backend_pids"]))
conn=psycopg2.connect(host=plan["socket"],port=plan["port"],dbname=plan["database"],user=superuser)
for team in plan["teams"]:
    value=json.load(open(root/f"team_{team}.json"))
    assert value["report_id"]==plan["report_id"] and value["team"]==team and value["status"]=="complete"
    assert value["database"]==plan["database"] and value["role"]==plan["role"]
    assert value["transaction_read_only"] is True and value["snapshot"] and value["backend_pid"] in manifest["backend_pids"]
    with conn.cursor() as cur:
        cur.execute("""SELECT count(*)::bigint,count(*) FILTER (WHERE privileged)::bigint,
                              count(DISTINCT account_id)::bigint,
                              md5(string_agg(event_id::text || ':' || action || ':' || privileged::text, ',' ORDER BY event_id))
                       FROM audit_events WHERE team=%s""",(team,))
        expected=cur.fetchone()
    actual=(value["row_count"],value["privileged_count"],value["distinct_accounts"],value["digest"])
    assert actual==expected
conn.close()
print(manifest["report_id"],len(manifest["teams"]),observed["peak_transactional_sessions"])
PY
)
rc=$?
set -e
if [ "$rc" = 0 ]; then
  read -r report teams observed <<< "$summary"
  echo "TASK_OK=1 REPORT_ID=$report SESSIONS=$observed TEAMS=$teams DATABASE=$PG_DATABASE ROLE=$B_DB_USER"
else
  echo "TASK_OK=0 OUTPUT=$OUTPUT REASON=missing_invalid_or_unobserved_access_snapshot"
  exit 1
fi
