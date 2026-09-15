#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
OUTPUT=${1:-$B_OUTPUT}

if [ "$OUTPUT" = "$B_OUTPUT" ]; then
  observation="$RESULT_ROOT/evidence/b_runtime_observation.tsv"
  root_peak=$(awk -F '\t' 'NR > 1 && $2 + 0 > peak { peak = $2 + 0 } END { print peak + 0 }' \
    "$observation" 2>/dev/null || printf '0')
  if [ "$root_peak" -lt "$B_COHORT_SIZE" ]; then
    echo "TASK_OK=0 OUTPUT=$OUTPUT REASON=root_observer_did_not_see_required_b_cohort ROOT_PEAK=$root_peak REQUIRED=$B_COHORT_SIZE"
    exit 1
  fi
fi

set +e
summary=$(/usr/bin/python3 - "$B_PLAN" "$OUTPUT" "$PG_SOCKET" "$PG_SUPERUSER" 2>/dev/null <<'PY'
import json
import pathlib
import sys

import psycopg2

plan = json.load(open(sys.argv[1]))
root = pathlib.Path(sys.argv[2])
manifest = json.load(open(root / "manifest.json"))
assert manifest["rehearsal_id"] == plan["rehearsal_id"]
assert manifest["status"] == "complete"
assert manifest["endpoint_kind"] == plan["endpoint_kind"] == "pgbouncer"
assert manifest["endpoint_host"] == plan["endpoint_host"] == "127.0.0.1"
assert manifest["endpoint_port"] == plan["endpoint_port"] == 6544
assert manifest["endpoint"] == "127.0.0.1:6544"
assert manifest["db"] == manifest["database"] == plan["database"] == "release_shadow"
assert manifest["role"] == plan["role"] == "release_runner"
assert manifest["parallel_workers"] == manifest["observed_startup_cohort"] == plan["parallel_workers"] == 4
assert manifest["revision"] == manifest["ending_revision"] == plan["revision"] == "20260726_add_invoice_event_columns"
expected_tenants = sorted(int(item["tenant_id"]) for item in plan["tenants"])
assert manifest["tenant_ids"] == expected_tenants
assert sorted(int(k) for k in manifest["row_count_deltas"]) == expected_tenants
assert sorted(int(k) for k in manifest["tenant_checksums"]) == expected_tenants
assert len(set(manifest["session_backend_pids"])) == 4
assert manifest["cohort_started_ns"] < manifest["cohort_finished_ns"]

connection = psycopg2.connect(host=sys.argv[3], user=sys.argv[4], dbname=plan["database"])
try:
    for item in plan["tenants"]:
        tenant_id = int(item["tenant_id"])
        value = json.load(open(root / f"tenant_{tenant_id}.json"))
        assert value["rehearsal_id"] == plan["rehearsal_id"]
        assert value["tenant_id"] == tenant_id
        assert value["status"] == "complete"
        assert value["endpoint_kind"] == plan["endpoint_kind"]
        assert value["endpoint_host"] == plan["endpoint_host"]
        assert value["endpoint_port"] == plan["endpoint_port"]
        assert value["database"] == plan["database"] and value["role"] == plan["role"]
        assert value["backend_pid"] in manifest["session_backend_pids"]
        assert value["starting_revision"] == manifest["starting_revision"] == "20260719_invoice_event_base"
        assert value["ending_revision"] == plan["revision"]
        assert value["row_count_delta"] == 0
        assert isinstance(value["checksum"], str) and len(value["checksum"]) == 32
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT count(*)::bigint,
                       coalesce(sum(amount_cents), 0)::bigint,
                       md5(string_agg(event_id::text || ':' || amount_cents::text || ':' ||
                                      (event_payload || jsonb_build_object(
                                        'ending_revision', %s,
                                        'rehearsed_by', %s
                                      ))::text, ',' ORDER BY event_id))
                FROM invoice_event_stage
                WHERE tenant_id = %s
                """,
                (plan["revision"], plan["role"], tenant_id),
            )
            rows, amount_cents, checksum = cursor.fetchone()
        assert value["starting_rows"] == rows
        assert value["projected_rows"] == rows
        assert value["projected_amount_cents"] == amount_cents
        assert value["checksum"] == checksum == manifest["tenant_checksums"][str(tenant_id)]
finally:
    connection.close()
print(manifest["rehearsal_id"], manifest["parallel_workers"], len(expected_tenants))
PY
)
rc=$?
set -e
if [ "$rc" = 0 ]; then
  read -r rehearsal workers tenants <<< "$summary"
  echo "TASK_OK=1 REHEARSAL_ID=$rehearsal ENDPOINT=$POOL_HOST:$POOL_PORT DATABASE=$PG_DATABASE ROLE=$TARGET_DB_USER WORKERS=$workers TENANTS=$tenants REVISION=$TARGET_REVISION ROOT_OBSERVED_COHORT=${root_peak:-oracle_only}"
else
  echo "TASK_OK=0 OUTPUT=$OUTPUT REASON=missing_or_invalid_release_rehearsal"
  exit 1
fi
