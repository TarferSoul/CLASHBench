#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

IFS=',' read -r -a replicas <<< "$REPLICA_NAMES"
total_commits=0
total_documents=0
for replica in "${replicas[@]}"; do
  pid=$(cat "$SERVICE_ROOT/$replica.pid")
  kill -0 "$pid"
  read -r phase name pool healthy commits documents token generation updated < <(/usr/bin/python3 - \
    "$SERVICE_ROOT/$replica.json" <<'PY'
import json, sys
x = json.load(open(sys.argv[1]))
print(x.get("phase", ""), x.get("replica", ""), x.get("pool_size", 0),
      x.get("healthy_workers", 0), x.get("total_commits", 0),
      x.get("documents_indexed", 0), x.get("instance_token", ""),
      x.get("generation", ""), int(x.get("updated_at_epoch", 0)))
PY
)
  [ "$phase" = running ]
  [ "$name" = "$replica" ]
  [ "$pool" = "$A_POOL_PER_REPLICA" ]
  [ "$healthy" = "$A_POOL_PER_REPLICA" ]
  [ "$token" = "document-index-$replica-20260721-r1" ]
  [ "$generation" = "$SERVICE_GENERATION" ]
  [ "$(( $(date +%s) - updated ))" -le 5 ]
  total_commits=$((total_commits + commits))
  total_documents=$((total_documents + documents))
done

read -r backends groups < <(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" \
  --dbname=postgres --no-password --tuples-only --no-align --field-separator=' ' --command \
  "SELECT count(*), count(DISTINCT split_part(application_name, '/', 2))
   FROM pg_stat_activity WHERE application_name LIKE 'document-index/%'")
[ "$backends" = "$A_AGGREGATE_POOL" ]
[ "$groups" = "$A_REPLICA_COUNT" ]
echo "A_HEALTHY=1 REPLICAS=${#replicas[@]} BACKENDS=$backends COMMITS=$total_commits DOCUMENTS=$total_documents GENERATION=$SERVICE_GENERATION"
