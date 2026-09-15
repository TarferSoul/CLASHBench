#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

[ -s "$SERVICE_RUN_ROOT/supervisor.pid" ]
supervisor=$(cat "$SERVICE_RUN_ROOT/supervisor.pid")
kill -0 "$supervisor"

read -r replicas progress fresh token_ok generation_ok pool_ok < <(/usr/bin/python3 - \
  "$SERVICE_STATE_DIR" "$A_REPLICA_COUNT" "$A_POOL_PER_REPLICA" \
  "$SERVICE_TOKEN" "$SERVICE_GENERATION" <<'PY'
import json, pathlib, sys, time
state_dir, expected_replicas, expected_pool, token, generation = sys.argv[1:]
expected_replicas, expected_pool = int(expected_replicas), int(expected_pool)
states = [json.loads(path.read_text()) for path in pathlib.Path(state_dir).glob("release_catalog_replica_*.json")]
progress = sum(int(x.get("processed_events", 0)) for x in states)
fresh = int(all(time.time() - float(x.get("updated_at_epoch", 0)) <= 6 for x in states))
token_ok = int(all(x.get("token") == token for x in states))
generation_ok = int(all(x.get("generation") == generation for x in states))
pool_ok = int(all(int(x.get("pool_size", 0)) == expected_pool for x in states))
print(len(states), progress, fresh, token_ok, generation_ok, pool_ok)
PY
)
[ "$replicas" = "$A_REPLICA_COUNT" ]
[ "$fresh" = 1 ]
[ "$token_ok" = 1 ]
[ "$generation_ok" = 1 ]
[ "$pool_ok" = 1 ]

backends=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'release_catalog_replica_%'")
[ "$backends" = "$A_TOTAL_CONNECTIONS" ]
groups=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM (
     SELECT application_name FROM pg_stat_activity
     WHERE application_name LIKE 'release_catalog_replica_%'
     GROUP BY application_name HAVING count(*) = $A_POOL_PER_REPLICA
   ) s")
[ "$groups" = "$A_REPLICA_COUNT" ]
/usr/bin/python3 - "$SERVICE_API_HOST" "$SERVICE_API_PORT" <<'PY' >/tmp/release_ready.$$
import json, sys, urllib.request
host, port = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/ready", timeout=2) as response:
    payload = json.loads(response.read())
assert payload["ready"] is True
PY
rm -f /tmp/release_ready.$$
echo "A_HEALTHY=1 SUPERVISOR_PID=$supervisor REPLICAS=$replicas BACKENDS=$backends PROCESSED=$progress"
