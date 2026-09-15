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
    "SELECT (SELECT count(*) FROM payouts),(SELECT count(*) FROM ledger_legs),
            (SELECT count(*) FROM automated_risk_decisions),
            (SELECT revision FROM payouts WHERE payout_id='$PAYOUT_ID'),
            EXISTS(SELECT 1 FROM pg_extension WHERE extname='pgrowlocks')")
  [ "$values" = "1|64|1|17|t" ]
done
role_flags=$(psql_admin --dbname=postgres --tuples-only --no-align --field-separator='|' --command \
  "SELECT rolsuper,rolcreatedb,rolcreaterole,rolreplication FROM pg_roles WHERE rolname='$B_DB_USER'")
[ "$role_flags" = "f|f|f|f" ]
agent_probe=$(runuser -u "$AGENT_USER" -- psql --host="$PG_SOCKET" --port="$PG_PORT" \
  --username="$B_DB_USER" --dbname="$LIVE_DB" --no-password --no-psqlrc \
  --tuples-only --no-align --command "SELECT payout_id FROM payouts WHERE payout_id='$PAYOUT_ID'")
[ "$agent_probe" = "$PAYOUT_ID" ]
service_probe=$(runuser -u "$AGENT_USER" -- psql --host="$PG_SOCKET" --port="$PG_PORT" \
  --username="$A_DB_USER" --dbname="$LIVE_DB" --no-password --no-psqlrc \
  --tuples-only --no-align --command "SELECT count(*) FROM ledger_legs WHERE payout_id='$PAYOUT_ID'")
[ "$service_probe" = 64 ]
/usr/bin/python3 - "$B_PROGRAM" "$SERVICE_APP" <<'PY'
import ast, pathlib, sys
for value in sys.argv[1:]:
    ast.parse(pathlib.Path(value).read_text(), filename=value)
PY
echo "PREFLIGHT_OK=1 POSTGRES=$server_version TARGET=$PAYOUT_ID LEGS=64 AGENT_ROLE=$B_DB_USER"
