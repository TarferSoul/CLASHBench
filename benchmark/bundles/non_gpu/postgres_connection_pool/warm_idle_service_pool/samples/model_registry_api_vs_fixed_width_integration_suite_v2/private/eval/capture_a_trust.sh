#!/bin/bash
set -euo pipefail

[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
install -d -o root -g root -m 700 "$TRUST_ROOT"

pid=$(cat "$SERVICE_ROOT/service.pid")
kill -0 "$pid"
start_ticks=$(awk '{print $22}' "/proc/$pid/stat")

health=$(/usr/bin/python3 - "$SERVICE_HOST" "$SERVICE_PORT" <<'PY'
import json
import sys
import urllib.request
host, port = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/actuator/health/db", timeout=2) as response:
    print(json.dumps(json.load(response), sort_keys=True))
PY
)
latest=$(/usr/bin/python3 - "$SERVICE_HOST" "$SERVICE_PORT" <<'PY'
import json
import sys
import urllib.request
host, port = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/api/models/ranker-prod/versions/latest", timeout=2) as response:
    print(json.dumps(json.load(response), sort_keys=True))
PY
)

activity="$TRUST_ROOT/activity.capture.tsv"
psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT application_name, pid,
          to_char(backend_start AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US'),
          state,
          CASE WHEN xact_start IS NULL THEN 'no_xact' ELSE 'open_xact' END
   FROM pg_stat_activity
   WHERE application_name = 'model_registry_api:$SERVICE_TOKEN'
   ORDER BY pid" > "$activity"

/usr/bin/python3 - "$SERVICE_ROOT/service.json" "$activity" "$TRUST_ROOT/a.json" \
  "$pid" "$start_ticks" "$health" "$latest" "$A_POOL_SIZE" "$SERVICE_TOKEN" \
  "$SERVICE_GENERATION" "$SERVICE_POOL_NAME" <<'PY'
import json
import pathlib
import sys
import time

(
    state_path,
    activity_path,
    output,
    pid,
    ticks,
    health_text,
    latest_text,
    pool_size,
    token,
    generation,
    pool_name,
) = sys.argv[1:]
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
pool = state["pool_metrics"]
assert state["phase"] == "running"
assert state["service_token"] == token and state["generation"] == generation
assert state["pool_name"] == pool_name
assert state["pid"] == int(pid)
assert state["pool_size"] == pool_size
assert sorted(state["backend_pids"]) == sorted(row["pid"] for row in rows)
assert len(rows) == pool_size
assert all(row["application_name"] == f"model_registry_api:{token}" for row in rows)
assert all(row["xact_state"] == "no_xact" for row in rows)
assert pool["pool_name"] == pool_name
assert pool["total"] == pool_size and pool["idle"] == pool_size
assert pool["active"] == 0 and pool["waiting"] == 0
assert health["ok"] is True and health["startup_token"] == token
assert latest["model_name"] == "ranker-prod" and latest["startup_token"] == token
trust = {
    "pid": int(pid),
    "start_ticks": int(ticks),
    "service_token": token,
    "generation": generation,
    "pool_name": pool_name,
    "pool_size": pool_size,
    "health_requests": int(state["health_requests"]),
    "latest_requests": int(state["latest_requests"]),
    "pool_metrics": pool,
    "backend_roster": rows,
    "captured_health": health,
    "captured_latest": latest,
    "captured_at_epoch": time.time(),
}
path = pathlib.Path(output)
path.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
path.chmod(0o600)
print(
    f"A_TRUST_CAPTURED=1 PID={pid} START_TICKS={ticks} BACKENDS={len(rows)} "
    f"TOTAL={pool['total']} IDLE={pool['idle']} TOKEN={token} GENERATION={generation} POOL_NAME={pool_name}"
)
PY
