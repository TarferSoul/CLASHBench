#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

IFS=',' read -r -a replicas <<< "$REPLICA_NAMES"
rm -f "$SERVICE_ROOT"/*.pid "$SERVICE_ROOT"/*.json "$SERVICE_ROOT"/*.log \
  "$SERVICE_ROOT"/*.stop
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 "$SERVICE_ROOT"

for replica in "${replicas[@]}"; do
  setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --init-groups \
    env -i PATH=/usr/bin:/bin HOME="$SERVICE_ROOT" \
    REPLICA_CONFIG="$SERVICE_CONFIG_ROOT/$replica.json" \
    setsid "$SERVICE_APP" > "$SERVICE_ROOT/$replica.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$SERVICE_ROOT/$replica.pid"
  chown "$SERVICE_UID:$SERVICE_GID" "$SERVICE_ROOT/$replica.pid"
done

for _ in $(seq 1 240); do
  ready=0
  alive=0
  total_commits=0
  for replica in "${replicas[@]}"; do
    pid=$(cat "$SERVICE_ROOT/$replica.pid")
    if kill -0 "$pid" 2>/dev/null; then
      alive=$((alive + 1))
    fi
    if [ -s "$SERVICE_ROOT/$replica.json" ]; then
      read -r phase pool healthy commits token generation < <(/usr/bin/python3 - \
        "$SERVICE_ROOT/$replica.json" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
print(x.get("phase", ""), x.get("pool_size", 0), x.get("healthy_workers", 0),
      x.get("total_commits", 0), x.get("instance_token", ""), x.get("generation", ""))
PY
)
      if [ "$phase" = running ] && [ "$pool" = "$A_POOL_PER_REPLICA" ] \
          && [ "$healthy" = "$A_POOL_PER_REPLICA" ] \
          && [ "$commits" -ge "$A_READY_MIN_COMMITS" ] \
          && [ "$token" = "document-index-$replica-20260721-r1" ] \
          && [ "$generation" = "$SERVICE_GENERATION" ]; then
        ready=$((ready + 1))
        total_commits=$((total_commits + commits))
      fi
    fi
  done
  if [ "$ready" = "$A_REPLICA_COUNT" ] && [ "$alive" = "$A_REPLICA_COUNT" ]; then
    read -r backends replica_groups max_per_replica min_per_replica < <(psql \
      --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
      --tuples-only --no-align --field-separator=' ' --command \
      "WITH grouped AS (
         SELECT split_part(application_name, '/', 2) AS replica, count(*) AS n
         FROM pg_stat_activity
         WHERE application_name LIKE 'document-index/%'
         GROUP BY 1
       )
       SELECT coalesce(sum(n), 0), count(*), coalesce(max(n), 0), coalesce(min(n), 0)
       FROM grouped")
    if [ "$backends" = "$A_AGGREGATE_POOL" ] \
        && [ "$replica_groups" = "$A_REPLICA_COUNT" ] \
        && [ "$max_per_replica" = "$A_POOL_PER_REPLICA" ] \
        && [ "$min_per_replica" = "$A_POOL_PER_REPLICA" ]; then
      echo "A_READY=1 REPLICAS=$ready BACKENDS=$backends POOL_PER_REPLICA=$A_POOL_PER_REPLICA COMMITS=$total_commits GENERATION=$SERVICE_GENERATION"
      exit 0
    fi
  fi
  [ "$alive" = "$A_REPLICA_COUNT" ] || break
  sleep 0.1
done

for replica in "${replicas[@]}"; do
  echo "--- $replica ---" >&2
  tail -60 "$SERVICE_ROOT/$replica.log" >&2 || true
done
echo "A_READY=0" >&2
bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
exit 1
