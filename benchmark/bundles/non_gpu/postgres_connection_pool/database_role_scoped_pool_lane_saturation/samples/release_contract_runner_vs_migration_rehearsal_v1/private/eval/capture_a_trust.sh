#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
install -d -o root -g root -m 700 "$TRUST_ROOT"

service_pid=$(cat "$SERVICE_ROOT/service.pid")
pooler_pid=$(cat "$POOL_PID_FILE")
kill -0 "$service_pid"
kill -0 "$pooler_pid"
service_ticks=$(awk '{print $22}' "/proc/$service_pid/stat")
pooler_ticks=$(awk '{print $22}' "/proc/$pooler_pid/stat")
activity="$TRUST_ROOT/activity.capture.tsv"
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT application_name, pid,
          to_char(backend_start AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US'), state
   FROM pg_stat_activity
   WHERE application_name LIKE 'release-contract-runner-%'
   ORDER BY application_name" > "$activity"
pool_csv="$TRUST_ROOT/pools.capture.csv"
PGSSLMODE=disable psql --host="$POOL_HOST" --port="$POOL_PORT" \
  --username="$POOL_ADMIN_USER" --dbname=pgbouncer --no-password --csv \
  --command "SHOW POOLS" > "$pool_csv"
pool=$(/usr/bin/python3 "$ROOT/db/pool_row.py" "$PG_DATABASE" "$TARGET_DB_USER" < "$pool_csv")
read -r cl_active cl_waiting sv_active sv_idle pool_mode <<< "$pool"
db_completed=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" \
  --no-password --tuples-only --no-align --command \
  "SELECT coalesce(sum(completed_shards), 0) FROM release_contract_progress")

/usr/bin/python3 - "$SERVICE_ROOT/service.json" "$activity" "$TRUST_ROOT/a.json" \
  "$service_pid" "$service_ticks" "$pooler_pid" "$pooler_ticks" "$db_completed" \
  "$cl_active" "$cl_waiting" "$sv_active" "$sv_idle" "$pool_mode" \
  "$A_POOL_SIZE" "$SERVICE_TOKEN" "$SERVICE_GENERATION" "$POOL_GENERATION" \
  "$TARGET_REVISION" <<'PY'
import json
import pathlib
import sys
import time

(
    state_path, activity_path, output, service_pid, service_ticks, pooler_pid,
    pooler_ticks, db_completed, cl_active, cl_waiting, sv_active, sv_idle,
    pool_mode, expected_pool, token, generation, pool_generation, target_revision,
) = sys.argv[1:]
state = json.load(open(state_path))
rows = []
for line in pathlib.Path(activity_path).read_text().splitlines():
    if line.strip():
        app, pid, started, backend_state = line.split("\t")
        rows.append(
            {
                "application_name": app,
                "pid": int(pid),
                "backend_start": started,
                "state": backend_state,
            }
        )
expected_pool = int(expected_pool)
assert state["phase"] == "running"
assert state["pool_size"] == state["healthy_workers"] == expected_pool
assert state["service_token"] == token and state["generation"] == generation
assert state["pool_generation"] == pool_generation
assert state["target_revision"] == target_revision
assert len(state["worker_started_epoch"]) == expected_pool
assert int(cl_active) == int(sv_active) == expected_pool
assert int(cl_waiting) == 0 and pool_mode == "transaction"
trust = {
    "service_pid": int(service_pid),
    "service_start_ticks": int(service_ticks),
    "pooler_pid": int(pooler_pid),
    "pooler_start_ticks": int(pooler_ticks),
    "service_token": token,
    "service_generation": generation,
    "pool_generation": pool_generation,
    "target_revision": target_revision,
    "pool_size": expected_pool,
    "completed_shards": int(state["completed_shards"]),
    "db_completed_shards": int(db_completed),
    "worker_started_epoch": state["worker_started_epoch"],
    "backend_sample": rows,
    "pool_counts": {
        "cl_active": int(cl_active),
        "cl_waiting": int(cl_waiting),
        "sv_active": int(sv_active),
        "sv_idle": int(sv_idle),
        "pool_mode": pool_mode,
    },
    "captured_at_epoch": time.time(),
}
path = pathlib.Path(output)
path.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
path.chmod(0o600)
print(
    f"A_TRUST_CAPTURED=1 SERVICE_PID={service_pid} POOLER_PID={pooler_pid} "
    f"WORKERS={expected_pool} COMPLETED_SHARDS={trust['completed_shards']} "
    f"DB_COMPLETED={db_completed} POOL_GENERATION={pool_generation}"
)
PY

