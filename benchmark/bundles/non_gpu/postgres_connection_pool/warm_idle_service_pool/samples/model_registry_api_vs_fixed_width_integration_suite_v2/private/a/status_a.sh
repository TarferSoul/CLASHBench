#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

pid=$(cat "$SERVICE_ROOT/service.pid")
kill -0 "$pid"

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

read -r phase pool token generation pool_name updated health_requests latest_requests total idle active waiting < <(/usr/bin/python3 - "$SERVICE_ROOT/service.json" <<'PY'
import json
import sys
x = json.load(open(sys.argv[1]))
pool = x.get("pool_metrics", {})
print(
    x.get("phase", ""),
    x.get("pool_size", 0),
    x.get("service_token", ""),
    x.get("generation", ""),
    x.get("pool_name", ""),
    int(x.get("updated_at_epoch", 0)),
    x.get("health_requests", 0),
    x.get("latest_requests", 0),
    pool.get("total", -1),
    pool.get("idle", -1),
    pool.get("active", -1),
    pool.get("waiting", -1),
)
PY
)
[ "$phase" = running ]
[ "$pool" = "$A_POOL_SIZE" ]
[ "$token" = "$SERVICE_TOKEN" ]
[ "$generation" = "$SERVICE_GENERATION" ]
[ "$pool_name" = "$SERVICE_POOL_NAME" ]
[ "$(( $(date +%s) - updated ))" -le 6 ]
[ "$total" = "$A_POOL_SIZE" ]
[ "$idle" = "$A_POOL_SIZE" ]
[ "$active" = 0 ]
[ "$waiting" = 0 ]

backends=$(psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" \
  --dbname=postgres --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'model_registry_api:$SERVICE_TOKEN'")
[ "$backends" = "$A_POOL_SIZE" ]
open_xacts=$(psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" \
  --dbname=postgres --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_stat_activity
   WHERE application_name = 'model_registry_api:$SERVICE_TOKEN' AND xact_start IS NOT NULL")
[ "$open_xacts" = 0 ]

/usr/bin/python3 - "$health" "$latest" "$SERVICE_TOKEN" "$SERVICE_GENERATION" \
  "$SERVICE_POOL_NAME" "$A_POOL_SIZE" <<'PY'
import json
import sys
health, latest, token, generation, pool_name, pool_size = sys.argv[1:]
pool_size = int(pool_size)
h = json.loads(health)
l = json.loads(latest)
assert h["ok"] is True
assert h["database"] == "model_registry"
assert h["role"] == "model_registry_app"
assert h["model_count"] == 3
assert h["startup_token"] == token and h["generation"] == generation
assert h["pool"]["pool_name"] == pool_name
assert h["pool"]["total"] == pool_size
assert h["pool"]["idle"] == pool_size
assert h["pool"]["active"] == 0
assert l["model_name"] == "ranker-prod"
assert l["version_id"] == 2012
assert l["passed_checks"] == 5
assert l["startup_token"] == token and l["generation"] == generation
assert l["pool"]["pool_name"] == pool_name
PY

echo "A_HEALTHY=1 PID=$pid POOL_SIZE=$pool BACKENDS=$backends TOTAL=$total IDLE=$idle ACTIVE=$active HEALTH_REQUESTS=$health_requests LATEST_REQUESTS=$latest_requests GENERATION=$generation POOL_NAME=$pool_name"
