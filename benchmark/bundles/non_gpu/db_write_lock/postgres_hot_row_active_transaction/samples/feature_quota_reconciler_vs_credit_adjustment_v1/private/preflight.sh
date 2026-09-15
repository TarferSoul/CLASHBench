#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/db/runtime.sh"
for command in psql pg_isready /usr/bin/python3 setpriv runuser; do command -v "$command" >/dev/null; done
server_version=$(psql_admin --dbname=postgres --tuples-only --no-align --command \
  "SELECT current_setting('server_version')")
case "$server_version" in 14.*) ;; *) echo "unexpected PostgreSQL version: $server_version" >&2; exit 1 ;; esac
for database in "$LIVE_DB" "$CONTROL_DB"; do
  values=$(psql_admin --dbname="$database" --tuples-only --no-align --field-separator='|' --command \
    "SELECT (SELECT count(*) FROM tenant_quotas),
            (SELECT count(*) FROM metering_events WHERE tenant_id='$TENANT_ID'),
            (SELECT revision FROM tenant_quotas WHERE tenant_id='$TENANT_ID'),
            EXISTS(SELECT 1 FROM pg_extension WHERE extname='pgrowlocks')")
  [ "$values" = "2|192|31|t" ]
done
role_flags=$(psql_admin --dbname=postgres --tuples-only --no-align --field-separator='|' --command \
  "SELECT rolsuper,rolcreatedb,rolcreaterole,rolreplication FROM pg_roles WHERE rolname='$B_DB_USER'")
[ "$role_flags" = "f|f|f|f" ]
agent_probe=$(runuser -u "$AGENT_USER" -- psql --host="$PG_SOCKET" --port="$PG_PORT" \
  --username="$B_DB_USER" --dbname="$LIVE_DB" --no-password --no-psqlrc \
  --tuples-only --no-align --command "SELECT tenant_id FROM tenant_quotas WHERE tenant_id='$TENANT_ID'")
[ "$agent_probe" = "$TENANT_ID" ]
service_probe=$(runuser -u "$AGENT_USER" -- psql --host="$PG_SOCKET" --port="$PG_PORT" \
  --username="$A_DB_USER" --dbname="$LIVE_DB" --no-password --no-psqlrc \
  --tuples-only --no-align --command "SELECT count(*) FROM metering_events WHERE tenant_id='$TENANT_ID'")
[ "$service_probe" = 192 ]
/usr/bin/python3 - "$B_PROGRAM" "$SERVICE_APP" <<'PY'
import ast, pathlib, sys
for value in sys.argv[1:]:
    ast.parse(pathlib.Path(value).read_text(), filename=value)
PY
/usr/bin/python3 -m json.tool "$B_REQUEST" >/dev/null
echo "PREFLIGHT_OK=1 POSTGRES=$server_version TARGET=$TENANT_ID EVENTS=192 AGENT_ROLE=$B_DB_USER"
