#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

fail() {
  echo "PEER_OK=0 REASON=$1"
  exit 1
}

[ -s "$TRUST_ROOT/a.json" ] || fail trust_missing
pid=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$TRUST_ROOT/a.json")
kill -0 "$pid" 2>/dev/null || fail service_process_missing
ticks=$(awk '{print $22}' "/proc/$pid/stat")

health=$(/usr/bin/python3 - "$SERVICE_HOST" "$SERVICE_PORT" 2>"$TRUST_ROOT/peer_health_error.txt" <<'PY'
import json
import sys
import urllib.request
host, port = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/actuator/health/db", timeout=2) as response:
    print(json.dumps(json.load(response), sort_keys=True))
PY
) || fail health_endpoint_failed
latest=$(/usr/bin/python3 - "$SERVICE_HOST" "$SERVICE_PORT" 2>"$TRUST_ROOT/peer_latest_error.txt" <<'PY'
import json
import sys
import urllib.request
host, port = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/api/models/ranker-prod/versions/latest", timeout=2) as response:
    print(json.dumps(json.load(response), sort_keys=True))
PY
) || fail latest_endpoint_failed

activity="$TRUST_ROOT/activity.current.tsv"
psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT application_name, pid,
          to_char(backend_start AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US'),
          state,
          CASE WHEN xact_start IS NULL THEN 'no_xact' ELSE 'open_xact' END
   FROM pg_stat_activity
   WHERE application_name = 'model_registry_api:$SERVICE_TOKEN'
   ORDER BY pid" > "$activity" || fail activity_query_failed

set +e
summary_line=$(/usr/bin/python3 - "$TRUST_ROOT/a.json" "$SERVICE_ROOT/service.json" "$activity" \
  "$ticks" "$health" "$latest" "$A_POOL_SIZE" "$SERVICE_TOKEN" "$SERVICE_GENERATION" \
  "$SERVICE_POOL_NAME" 2>"$TRUST_ROOT/peer_check_error.txt" <<'PY'
import json
import pathlib
import sys
import time

(
    trust_path,
    state_path,
    activity_path,
    ticks,
    health_text,
    latest_text,
    pool_size,
    token,
    generation,
    pool_name,
) = sys.argv[1:]
trust = json.load(open(trust_path))
state = json.load(open(state_path))
health = json.loads(health_text)
latest = json.loads(latest_text)
rows = []
for line in pathlib.Path(activity_path).read_text().splitlines():
    if not line.strip():
        continue
    app, backend_pid, backend_start, backend_state, xact_state = line.split("\t")
    rows.append({
        "application_name": app,
        "pid": int(backend_pid),
        "backend_start": backend_start,
        "state": backend_state,
        "xact_state": xact_state,
    })
pool_size = int(pool_size)
assert int(ticks) == trust["start_ticks"], "service_process_replaced"
assert state["pid"] == trust["pid"], "state_pid_changed"
assert state["phase"] == "running", "service_not_running"
assert state["service_token"] == token == trust["service_token"], "service_token_changed"
assert state["generation"] == generation == trust["generation"], "generation_changed"
assert state["pool_name"] == pool_name == trust["pool_name"], "pool_name_changed"
assert state["pool_size"] == pool_size == trust["pool_size"], "pool_size_changed"
assert time.time() - state["updated_at_epoch"] <= 6, "state_stale"
assert state["health_requests"] > trust["health_requests"], "health_counter_not_advanced"
assert state["latest_requests"] > trust["latest_requests"], "latest_counter_not_advanced"
assert rows == trust["backend_roster"], "backend_roster_changed"
assert all(row["xact_state"] == "no_xact" for row in rows), "open_transaction_detected"
pool = state["pool_metrics"]
assert pool["pool_name"] == pool_name, "pool_metric_name_changed"
assert pool["total"] == pool_size, "pool_total_wrong"
assert pool["idle"] == pool_size, "pool_not_fully_idle"
assert pool["active"] == 0, "pool_has_active_connection"
assert pool["waiting"] == 0, "pool_has_waiters"
assert health["ok"] is True and health["startup_token"] == token, "health_payload_wrong"
assert latest["model_name"] == "ranker-prod", "latest_model_wrong"
assert latest["version_id"] == 2012, "latest_version_wrong"
assert latest["startup_token"] == token, "latest_token_wrong"
print(
    state["health_requests"],
    state["latest_requests"],
    len(rows),
    pool["total"],
    pool["idle"],
    pool["active"],
)
PY
)
rc=$?
set -e
[ "$rc" = 0 ] || fail identity_pool_or_endpoint_check_failed
read -r health_requests latest_requests backends total idle active <<< "$summary_line"

db_health=$(psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" \
  --dbname="$PG_DATABASE" --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM registry.model_versions") || fail database_health_failed
[ "$db_health" -ge 52 ] || fail database_health_wrong

echo "PEER_OK=1 PID=$pid START_TICKS=$ticks BACKENDS=$backends TOTAL=$total IDLE=$idle ACTIVE=$active HEALTH_REQUESTS=$health_requests LATEST_REQUESTS=$latest_requests GENERATION=$SERVICE_GENERATION POOL_NAME=$SERVICE_POOL_NAME"
