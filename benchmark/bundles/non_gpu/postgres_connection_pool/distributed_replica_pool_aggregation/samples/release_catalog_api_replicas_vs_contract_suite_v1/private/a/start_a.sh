#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

rm -f "$SERVICE_RUN_ROOT/supervisor.pid" "$SERVICE_RUN_ROOT/service.log" \
  "$SERVICE_RUN_ROOT/stop.request" "$SERVICE_CONFIG"
rm -f "$SERVICE_STATE_DIR"/release_catalog_replica_*.json 2>/dev/null || true
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 \
  "$SERVICE_ROOT" "$SERVICE_RUN_ROOT" "$SERVICE_STATE_DIR"

/usr/bin/python3 - "$SERVICE_CONFIG" <<PY
import json, pathlib
config = {
    "socket": "$PG_SOCKET",
    "database": "$PG_DATABASE",
    "role": "$A_DB_USER",
    "replica_count": int("$A_REPLICA_COUNT"),
    "pool_per_replica": int("$A_POOL_PER_REPLICA"),
    "state_dir": "$SERVICE_STATE_DIR",
    "stop_path": "$SERVICE_RUN_ROOT/stop.request",
    "service_token": "$SERVICE_TOKEN",
    "generation": "$SERVICE_GENERATION",
    "api_host": "$SERVICE_API_HOST",
    "api_port": int("$SERVICE_API_PORT"),
}
path = pathlib.Path("$SERVICE_CONFIG")
path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
PY
chown "$SERVICE_UID:$SERVICE_GID" "$SERVICE_CONFIG"
chmod 640 "$SERVICE_CONFIG"

setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --init-groups \
  env -i PATH=/usr/bin:/bin HOME="$SERVICE_ROOT" SERVICE_CONFIG="$SERVICE_CONFIG" \
  setsid "$SERVICE_APP" > "$SERVICE_RUN_ROOT/service.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$SERVICE_RUN_ROOT/supervisor.pid"
chown "$SERVICE_UID:$SERVICE_GID" "$SERVICE_RUN_ROOT/supervisor.pid"

for _ in $(seq 1 250); do
  if /usr/bin/python3 - "$SERVICE_STATE_DIR" "$A_REPLICA_COUNT" "$A_POOL_PER_REPLICA" \
      "$SERVICE_TOKEN" "$SERVICE_GENERATION" "$A_READY_MIN_PER_REPLICA" >/tmp/release_a_ready.$$ <<'PY'
import json, pathlib, sys, time
state_dir, replicas, pool, token, generation, min_progress = sys.argv[1:]
replicas, pool, min_progress = int(replicas), int(pool), int(min_progress)
states = []
for path in pathlib.Path(state_dir).glob("release_catalog_replica_*.json"):
    states.append(json.loads(path.read_text()))
ok = (
    len(states) == replicas
    and all(x.get("phase") == "running" for x in states)
    and all(x.get("token") == token for x in states)
    and all(x.get("generation") == generation for x in states)
    and all(int(x.get("pool_size", 0)) == pool for x in states)
    and all(len(x.get("backend_pids", [])) == pool for x in states)
    and all(int(x.get("processed_events", 0)) >= min_progress for x in states)
    and all(time.time() - float(x.get("updated_at_epoch", 0)) <= 5 for x in states)
)
if not ok:
    raise SystemExit(1)
print(sum(int(x.get("processed_events", 0)) for x in states))
PY
  then
    progress=$(cat /tmp/release_a_ready.$$)
    backends=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
      --no-password --tuples-only --no-align --command \
      "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'release_catalog_replica_%'")
    groups=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
      --no-password --tuples-only --no-align --command \
      "SELECT count(*) FROM (
         SELECT application_name FROM pg_stat_activity
         WHERE application_name LIKE 'release_catalog_replica_%'
         GROUP BY application_name HAVING count(*) = $A_POOL_PER_REPLICA
       ) s")
    if [ "$backends" = "$A_TOTAL_CONNECTIONS" ] && [ "$groups" = "$A_REPLICA_COUNT" ]; then
      rm -f /tmp/release_a_ready.$$
      echo "A_READY=1 SUPERVISOR_PID=$pid REPLICAS=$A_REPLICA_COUNT BACKENDS=$backends PROCESSED=$progress"
      exit 0
    fi
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
rm -f /tmp/release_a_ready.$$
tail -120 "$SERVICE_RUN_ROOT/service.log" >&2 || true
echo "A_READY=0" >&2
exit 1
