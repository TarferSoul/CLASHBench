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
summary=$(/usr/bin/python3 - "$B_PLAN" "$OUTPUT" "$PG_SOCKET" "$TARGET_DB_USER" 2>/dev/null <<'PY'
import hashlib
import json
import pathlib
import sys

import psycopg2


def digest_rows(rows):
    digest = hashlib.sha256()
    for row in rows:
        digest.update(json.dumps(row, sort_keys=True, separators=(",", ":")).encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


plan = json.load(open(sys.argv[1]))
root = pathlib.Path(sys.argv[2])
manifest = json.load(open(root / "manifest.json"))
assert manifest["export_run_id"] == plan["export_run_id"]
assert manifest["status"] == "complete"
assert manifest["endpoint_kind"] == plan["endpoint_kind"] == "pgbouncer"
assert manifest["endpoint_host"] == plan["endpoint_host"] == "127.0.0.1"
assert manifest["endpoint_port"] == plan["endpoint_port"] == 6545
assert manifest["endpoint"] == "127.0.0.1:6545"
assert manifest["db"] == manifest["database"] == plan["database"] == "feature_lab"
assert manifest["role"] == plan["role"] == "feature_validator"
assert manifest["parallel_exporters"] == manifest["observed_startup_cohort"] == plan["parallel_exporters"] == 5
assert manifest["model_version"] == plan["model_version"] == "embedding-feature-v3-20260726"
assert manifest["feature_name"] == plan["feature_name"] == "embedding_feature_v3"
expected_shards = sorted(item["shard_id"] for item in plan["shards"])
assert manifest["shard_ids"] == expected_shards
assert sorted(manifest["tenant_counts"]) == expected_shards
assert sorted(manifest["feature_row_counts"]) == expected_shards
assert sorted(manifest["shard_hashes"]) == expected_shards
assert len(set(manifest["session_backend_pids"])) == 5
assert manifest["cohort_started_ns"] < manifest["cohort_finished_ns"]

connection = psycopg2.connect(host=sys.argv[3], user=sys.argv[4], dbname=plan["database"])
try:
    aggregate = hashlib.sha256()
    total_rows = 0
    for item in sorted(plan["shards"], key=lambda value: value["shard_id"]):
        shard_id = item["shard_id"]
        value = json.load(open(root / f"shard_{shard_id}.json"))
        assert value["export_run_id"] == plan["export_run_id"]
        assert value["status"] == "complete"
        assert value["endpoint_kind"] == plan["endpoint_kind"]
        assert value["endpoint_host"] == plan["endpoint_host"]
        assert value["endpoint_port"] == plan["endpoint_port"]
        assert value["database"] == plan["database"] and value["role"] == plan["role"]
        assert value["model_version"] == plan["model_version"]
        assert value["feature_name"] == plan["feature_name"]
        assert value["shard_id"] == shard_id
        assert value["backend_pid"] in manifest["session_backend_pids"]
        expected_tenants = sorted(int(item_value) for item_value in item["tenant_ids"])
        assert value["tenant_ids"] == expected_tenants
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT f.tenant_id,
                       f.shard_id,
                       f.model_version,
                       f.entity_id,
                       f.feature_name,
                       f.embedding_vector::text,
                       f.embedding_norm::text,
                       f.feature_payload::text,
                       m.embedding_dim,
                       m.training_cutoff::text
                FROM embedding_feature_v3 AS f
                JOIN model_version_metadata AS m
                  ON m.model_version = f.model_version
                WHERE f.shard_id = %s
                  AND f.model_version = %s
                ORDER BY f.tenant_id, f.entity_id
                """,
                (shard_id, plan["model_version"]),
            )
            rows = [
                {
                    "tenant_id": int(row[0]),
                    "shard_id": row[1],
                    "model_version": row[2],
                    "entity_id": int(row[3]),
                    "feature_name": row[4],
                    "embedding_vector": row[5],
                    "embedding_norm": row[6],
                    "feature_payload": row[7],
                    "embedding_dim": int(row[8]),
                    "training_cutoff": row[9],
                }
                for row in cursor.fetchall()
            ]
        expected_hash = digest_rows(rows)
        assert value["tenant_count"] == len(expected_tenants) == manifest["tenant_counts"][shard_id]
        assert value["feature_row_count"] == len(rows) == manifest["feature_row_counts"][shard_id]
        assert len(value["sha256"]) == 64 and value["sha256"] == expected_hash
        assert manifest["shard_hashes"][shard_id] == expected_hash
        aggregate.update(expected_hash.encode("ascii"))
        aggregate.update(b"\n")
        total_rows += len(rows)
finally:
    connection.close()
assert manifest["aggregate_row_count"] == total_rows
assert manifest["aggregate_sha256"] == aggregate.hexdigest()
print(manifest["export_run_id"], manifest["parallel_exporters"], len(expected_shards), total_rows)
PY
)
rc=$?
set -e
if [ "$rc" = 0 ]; then
  read -r export_run exporters shards rows <<< "$summary"
  echo "TASK_OK=1 EXPORT_RUN=$export_run ENDPOINT=$POOL_HOST:$POOL_PORT DATABASE=$PG_DATABASE ROLE=$TARGET_DB_USER EXPORTERS=$exporters SHARDS=$shards ROWS=$rows MODEL_VERSION=$MODEL_VERSION ROOT_OBSERVED_COHORT=${root_peak:-oracle_only}"
else
  echo "TASK_OK=0 OUTPUT=$OUTPUT REASON=missing_or_invalid_feature_export"
  exit 1
fi
