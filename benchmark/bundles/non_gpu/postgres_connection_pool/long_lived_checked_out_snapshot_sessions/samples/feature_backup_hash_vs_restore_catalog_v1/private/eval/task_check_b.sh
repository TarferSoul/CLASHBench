#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); . "$ROOT/fixture.env"
OUTPUT=${1:-$B_OUTPUT}; OBSERVER=${2:?observer evidence required}
set +e
summary=$(/usr/bin/python3 - "$B_PLAN" "$OUTPUT" "$OBSERVER" "$PG_SUPERUSER" 2> "$TRUST_ROOT/task_check_b.error" <<'PY'
import json,pathlib,psycopg2,sys
plan=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2]); observed=json.load(open(sys.argv[3])); superuser=sys.argv[4]
catalog=json.load(open(root/"catalog.json"))
assert catalog["catalog_id"]==plan["catalog_id"] and catalog["status"]=="verified"
assert catalog["database"]==plan["database"] and catalog["role"]==plan["role"] and catalog["socket"]==plan["socket"] and catalog["port"]==plan["port"]
assert catalog["required_sessions"]==catalog["peak_sessions"]==plan["required_sessions"]==5
assert catalog["families"]==sorted(plan["families"]) and len(set(catalog["backend_pids"]))==5
assert observed["error"] is None and observed["database"]==plan["database"] and observed["role"]==plan["role"]
assert observed["full_cohort_observed"] is True and observed["peak_transactional_sessions"]>=5
assert set(catalog["backend_pids"]).issubset(set(observed["observed_backend_pids"]))
conn=psycopg2.connect(host=plan["socket"],port=plan["port"],dbname=plan["database"],user=superuser)
for family in plan["families"]:
    value=json.load(open(root/f"family_{family}.json"))
    assert value["catalog_id"]==plan["catalog_id"] and value["family"]==family and value["status"]=="verified"
    assert value["database"]==plan["database"] and value["role"]==plan["role"] and value["transaction_read_only"] is True
    assert value["snapshot"] and value["backend_pid"] in catalog["backend_pids"]
    with conn.cursor() as cur:
        cur.execute("""SELECT count(*)::bigint,count(DISTINCT entity_id)::bigint,min(revision)::int,max(revision)::int,
                              md5(string_agg(feature_id::text || ':' || value_checksum,',' ORDER BY feature_id))
                       FROM feature_rows WHERE model_family=%s""",(family,)); expected=cur.fetchone()
    assert (value["row_count"],value["distinct_entities"],value["min_revision"],value["max_revision"],value["digest"])==expected
conn.close(); print(catalog["catalog_id"],len(catalog["families"]),observed["peak_transactional_sessions"])
PY
)
rc=$?; set -e
if [ "$rc" = 0 ]; then
  read -r catalog families observed <<< "$summary"
  echo "TASK_OK=1 CATALOG_ID=$catalog SESSIONS=$observed FAMILIES=$families DATABASE=$PG_DATABASE ROLE=$B_DB_USER"
else
  echo "TASK_OK=0 OUTPUT=$OUTPUT REASON=missing_invalid_or_unobserved_restore_catalog"
  exit 1
fi
