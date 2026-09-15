#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

rm -f "$SERVICE_ROOT/export.pid" "$SERVICE_ROOT/export_state.json" \
  "$SERVICE_ROOT/export.log" "$SERVICE_ROOT/stop.request"
install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 755 "$SERVICE_ROOT"
setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --init-groups \
  env -i PATH=/usr/bin:/bin HOME="$SERVICE_ROOT" SERVICE_CONFIG="$SERVICE_CONFIG" \
  A_MAX_FETCHES="${A_MAX_FETCHES_OVERRIDE:-0}" \
  setsid "$SERVICE_APP" > "$SERVICE_ROOT/export.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$SERVICE_ROOT/export.pid"
chown "$AGENT_UID:$AGENT_GID" "$SERVICE_ROOT/export.pid"

for _ in $(seq 1 200); do
  if [ -s "$SERVICE_ROOT/export_state.json" ]; then
    read -r phase healthy fetches token generation < <(/usr/bin/python3 - "$SERVICE_ROOT/export_state.json" <<'PY'
import json, sys
x=json.load(open(sys.argv[1]))
print(x.get("phase", ""), x.get("healthy_workers", 0), x.get("total_fetches", 0),
      x.get("service_token", ""), x.get("generation", ""))
PY
)
    if [ "$phase" = running ] && [ "$healthy" = "$A_POOL_SIZE" ] \
        && [ "$fetches" -ge "$((A_POOL_SIZE * A_READY_MIN_FETCHES))" ] \
        && [ "$token" = "$SERVICE_TOKEN" ] && [ "$generation" = "$SERVICE_GENERATION" ]; then
      backends=$(psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" \
        --dbname=postgres --no-password --tuples-only --no-align --command \
        "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '$A_APPLICATION_PREFIX/%'")
      if [ "$backends" = "$A_POOL_SIZE" ]; then
        echo "A_READY=1 PID=$pid BACKENDS=$backends FETCHES=$fetches GENERATION=$generation"
        exit 0
      fi
    fi
    [ "$phase" != failed ] || break
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
tail -100 "$SERVICE_ROOT/export.log" >&2 || true
echo "A_READY=0" >&2
exit 1
