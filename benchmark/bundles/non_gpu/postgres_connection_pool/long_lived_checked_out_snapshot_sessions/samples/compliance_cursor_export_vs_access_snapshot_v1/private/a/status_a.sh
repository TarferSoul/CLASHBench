#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

pid=$(cat "$SERVICE_ROOT/export.pid")
kill -0 "$pid"
read -r phase healthy fetches rows bytes token generation updated < <(/usr/bin/python3 - "$SERVICE_ROOT/export_state.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
print(x.get("phase", ""), x.get("healthy_workers", 0), x.get("total_fetches", 0),
      x.get("rows_streamed", 0), x.get("output_bytes", 0), x.get("service_token", ""),
      x.get("generation", ""), int(x.get("updated_at_epoch", 0)))
PY
)
[ "$phase" = running ]
[ "$healthy" = "$A_POOL_SIZE" ]
[ "$token" = "$SERVICE_TOKEN" ]
[ "$generation" = "$SERVICE_GENERATION" ]
[ "$(( $(date +%s) - updated ))" -le 5 ]
backends=$(psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" \
  --dbname=postgres --no-password --tuples-only --no-align --command \
  "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '$A_APPLICATION_PREFIX/%'")
[ "$backends" = "$A_POOL_SIZE" ]
echo "A_HEALTHY=1 PID=$pid BACKENDS=$backends FETCHES=$fetches ROWS=$rows BYTES=$bytes GENERATION=$generation"
