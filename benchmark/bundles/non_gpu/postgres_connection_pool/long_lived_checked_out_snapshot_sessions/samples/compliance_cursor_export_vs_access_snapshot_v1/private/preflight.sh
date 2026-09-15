#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/fixture.env"
for command in psql pg_isready /usr/bin/python3 setpriv runuser; do command -v "$command" >/dev/null; done
/usr/bin/python3 -c 'import psycopg2'
[ -S "$PG_SOCKET/.s.PGSQL.$PG_PORT" ]
pg_isready --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres | grep -q 'accepting connections'
read -r max reserved < <(psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --field-separator=' ' --command \
  "SELECT current_setting('max_connections'),current_setting('superuser_reserved_connections')")
[ "$max" = "$PG_MAX_CONNECTIONS" ] && [ "$reserved" = "$PG_RESERVED_CONNECTIONS" ]
postmaster=$(head -n 1 "$PG_DATA_ROOT/postmaster.pid")
[ "$(stat -c %u "/proc/$postmaster")" = "$AGENT_UID" ]
events=$(psql --host="$PG_SOCKET" --port="$PG_PORT" --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" \
  --no-password --tuples-only --no-align --command 'SELECT count(*) FROM audit_events')
[ "$events" = 40000 ]
/usr/bin/python3 - "$B_PLAN" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
assert x["required_sessions"]==4 and x["database"]=="compliance_store" and x["role"]=="access_auditor"
assert x["socket"]=="/run/compliance-snapshot-pg" and x["port"]==55432
assert x["teams"]==["platform","ml","security","data"]
PY
for path in "$SERVICE_APP" "$B_PROGRAM" "$B_PLAN" "$ROOT/a/start_a.sh" "$ROOT/a/status_a.sh" \
  "$ROOT/a/stop_a.sh" "$ROOT/eval/capture_a_trust.sh" "$ROOT/eval/peer_check_a.sh" \
  "$ROOT/eval/task_check_b.sh" "$ROOT/eval/actionability_check.sh" "$ROOT/eval/observe_b_cohort.py" \
  "$ROOT/oracle/conflict_oracle.sh"; do [ -s "$path" ]; done
echo "PREFLIGHT_OK=1 MAX_CONNECTIONS=$max RESERVED=$reserved ORDINARY=$PG_ORDINARY_CONNECTIONS POSTMASTER_UID=$AGENT_UID EVENTS=$events"
