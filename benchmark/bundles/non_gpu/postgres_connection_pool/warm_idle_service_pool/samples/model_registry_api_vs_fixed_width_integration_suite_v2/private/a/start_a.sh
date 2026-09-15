#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$ROOT/db/runtime.sh"

rm -f "$SERVICE_ROOT/service.pid" "$SERVICE_ROOT/service.json" "$SERVICE_ROOT/service.log" \
  "$SERVICE_ROOT/stop.request"
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 "$SERVICE_ROOT"

classpath="$SERVICE_CLASSES:$(java_classpath)"
setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --init-groups \
  env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$SERVICE_ROOT" \
  setsid java -cp "$classpath" ModelRegistryService "$SERVICE_CONFIG" \
  > "$SERVICE_ROOT/service.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$SERVICE_ROOT/service.pid"
chown "$SERVICE_UID:$SERVICE_GID" "$SERVICE_ROOT/service.pid"

for _ in $(seq 1 260); do
  if [ -s "$SERVICE_ROOT/service.json" ]; then
    read -r phase pool token generation pool_name total idle active waiting < <(/usr/bin/python3 - "$SERVICE_ROOT/service.json" <<'PY'
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
    pool.get("total", -1),
    pool.get("idle", -1),
    pool.get("active", -1),
    pool.get("waiting", -1),
)
PY
)
    if [ "$phase" = running ] && [ "$pool" = "$A_POOL_SIZE" ] \
        && [ "$token" = "$SERVICE_TOKEN" ] && [ "$generation" = "$SERVICE_GENERATION" ] \
        && [ "$pool_name" = "$SERVICE_POOL_NAME" ] && [ "$total" = "$A_POOL_SIZE" ] \
        && [ "$idle" = "$A_POOL_SIZE" ] && [ "$active" = 0 ] && [ "$waiting" = 0 ]; then
      backends=$(psql --host="$PG_HOST" --port="$PG_PORT" --username="$PG_SUPERUSER" \
        --dbname=postgres --no-password --tuples-only --no-align --command \
        "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'model_registry_api:$SERVICE_TOKEN'")
      if [ "$backends" = "$A_POOL_SIZE" ]; then
        if bash "$ROOT/a/status_a.sh" >/tmp/model_registry_start_status.txt 2>&1; then
          cat /tmp/model_registry_start_status.txt
          echo "A_READY=1 PID=$pid POOL_SIZE=$pool BACKENDS=$backends TOKEN=$token GENERATION=$generation POOL_NAME=$pool_name"
          exit 0
        fi
      fi
    fi
    [ "$phase" != failed ] || break
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
tail -120 "$SERVICE_ROOT/service.log" >&2 || true
echo "A_READY=0" >&2
exit 1
