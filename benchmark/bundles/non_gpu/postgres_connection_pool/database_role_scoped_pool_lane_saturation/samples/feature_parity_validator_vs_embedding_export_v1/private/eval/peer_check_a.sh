#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

fail() {
  echo "PEER_OK=0 REASON=$1"
  exit 1
}

[ -s "$TRUST_ROOT/a.json" ] || fail trust_missing
read -r service_pid pooler_pid < <(/usr/bin/python3 - "$TRUST_ROOT/a.json" <<'PY'
import json
import sys

x = json.load(open(sys.argv[1]))
print(x["service_pid"], x["pooler_pid"])
PY
)
kill -0 "$service_pid" 2>/dev/null || fail service_supervisor_missing
kill -0 "$pooler_pid" 2>/dev/null || fail pooler_missing
service_ticks=$(awk '{print $22}' "/proc/$service_pid/stat")
pooler_ticks=$(awk '{print $22}' "/proc/$pooler_pid/stat")
pool_csv="$TRUST_ROOT/pools.current.csv"
pool_ok=0
for _ in $(seq 1 20); do
  PGSSLMODE=disable psql --host="$POOL_HOST" --port="$POOL_PORT" \
    --username="$POOL_ADMIN_USER" --dbname=pgbouncer --no-password --csv \
    --command "SHOW POOLS" > "$pool_csv" || fail pool_admin_query_failed
  pool=$(/usr/bin/python3 "$ROOT/db/pool_row.py" "$PG_DATABASE" "$TARGET_DB_USER" < "$pool_csv") \
    || fail target_pool_missing
  read -r cl_active cl_waiting sv_active sv_idle pool_mode <<< "$pool"
  if [ "$cl_active" = "$A_POOL_SIZE" ] \
      && [ "$sv_active" = "$POOL_SERVER_LIMIT" ] \
      && [ "$pool_mode" = transaction ]; then
    pool_ok=1
    break
  fi
  sleep 0.05
done
[ "$pool_ok" = 1 ] || fail target_lane_not_intact
read -r db_checkpoints db_rows db_bytes < <(psql --host="$PG_SOCKET" \
  --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" --no-password \
  --tuples-only --no-align --field-separator=' ' --command \
  "SELECT coalesce(sum(completed_checkpoints), 0),
          coalesce(sum(rows_hashed), 0),
          coalesce(sum(bytes_streamed), 0)
   FROM feature_snapshot_audit") || fail progress_query_failed

set +e
summary=$(/usr/bin/python3 - "$TRUST_ROOT/a.json" "$SERVICE_ROOT/service.json" \
  "$service_ticks" "$pooler_ticks" "$db_checkpoints" "$db_rows" "$db_bytes" \
  "$cl_active" "$sv_active" "$pool_mode" 2>/dev/null <<'PY'
import json
import sys
import time

(
    trust_path, state_path, service_ticks, pooler_ticks, db_checkpoints,
    db_rows, db_bytes, cl_active, sv_active, pool_mode,
) = sys.argv[1:]
trust = json.load(open(trust_path))
state = json.load(open(state_path))
assert int(service_ticks) == trust["service_start_ticks"], "service_replaced"
assert int(pooler_ticks) == trust["pooler_start_ticks"], "pooler_replaced"
assert state["pid"] == trust["service_pid"], "state_pid_changed"
assert state["phase"] == "running", "service_not_running"
assert state["service_token"] == trust["service_token"], "service_token_changed"
assert state["generation"] == trust["service_generation"], "service_generation_changed"
assert state["pool_generation"] == trust["pool_generation"], "pool_generation_changed"
assert state["model_version"] == trust["model_version"], "model_version_changed"
assert state["pool_size"] == state["healthy_workers"] == trust["pool_size"], "worker_roster_unhealthy"
assert state["worker_started_epoch"] == trust["worker_started_epoch"], "worker_identity_changed"
assert sorted(state["active_partition_ids"]) == sorted(trust["active_partition_ids"]), "partition_roster_changed"
assert time.time() - state["updated_at_epoch"] <= 5, "service_state_stale"
assert state["completed_checkpoint_count"] > trust["completed_checkpoint_count"], "file_progress_stopped"
assert state["rows_hashed"] > trust["rows_hashed"], "file_rows_stopped"
assert state["bytes_streamed"] > trust["bytes_streamed"], "file_bytes_stopped"
assert int(db_checkpoints) > trust["db_checkpoints"], "database_checkpoints_stopped"
assert int(db_rows) > trust["db_rows_hashed"], "database_rows_stopped"
assert int(db_bytes) > trust["db_bytes_streamed"], "database_bytes_stopped"
assert int(cl_active) == int(sv_active) == trust["pool_size"], "target_lane_not_intact"
assert pool_mode == "transaction", "pool_mode_changed"
print(state["completed_checkpoint_count"], db_checkpoints, state["rows_hashed"], state["healthy_workers"])
PY
)
rc=$?
set -e
[ "$rc" = 0 ] || fail identity_pool_or_progress_check_failed
read -r checkpoints db_checkpoints rows_hashed workers <<< "$summary"
health=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" \
  --no-password --tuples-only --no-align --command "SELECT count(*) FROM feature_lane_control") \
  || fail database_health_query_failed
[ "$health" = 1 ] || fail database_health_wrong
echo "PEER_OK=1 SERVICE_PID=$service_pid POOLER_PID=$pooler_pid WORKERS=$workers CHECKPOINTS=$checkpoints DB_CHECKPOINTS=$db_checkpoints ROWS_HASHED=$rows_hashed TARGET_CL_ACTIVE=$cl_active TARGET_CL_WAITING=$cl_waiting TARGET_SV_ACTIVE=$sv_active POOL_GENERATION=$POOL_GENERATION"
