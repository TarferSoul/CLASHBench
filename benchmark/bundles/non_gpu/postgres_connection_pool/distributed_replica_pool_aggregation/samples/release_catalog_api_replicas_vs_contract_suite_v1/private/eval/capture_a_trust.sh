#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

install -d -o root -g root -m 700 "$TRUST_ROOT"
[ -s "$SERVICE_RUN_ROOT/supervisor.pid" ]
supervisor=$(cat "$SERVICE_RUN_ROOT/supervisor.pid")
kill -0 "$supervisor"

activity="$TRUST_ROOT/a_activity.tsv"
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT application_name, pid, usename, state,
          coalesce(wait_event_type, ''), coalesce(wait_event, ''),
          to_char(backend_start AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US')
   FROM pg_stat_activity
   WHERE application_name LIKE 'release_catalog_replica_%'
   ORDER BY application_name, pid" > "$activity"

/usr/bin/python3 - "$TRUST_ROOT/trust.json" "$SERVICE_STATE_DIR" "$activity" \
  "$supervisor" "$SERVICE_TOKEN" "$SERVICE_GENERATION" "$A_REPLICA_COUNT" \
  "$A_POOL_PER_REPLICA" <<'PY'
import json, pathlib, sys, time

out, state_dir, activity, supervisor, token, generation, replica_count, pool_size = sys.argv[1:]
replica_count, pool_size = int(replica_count), int(pool_size)

def start_ticks(pid):
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return int(fields[21])

states = []
for path in sorted(pathlib.Path(state_dir).glob("release_catalog_replica_*.json")):
    state = json.loads(path.read_text())
    state["start_ticks"] = start_ticks(state["pid"])
    states.append(state)

rows = []
for line in pathlib.Path(activity).read_text().splitlines():
    if line:
        app, pid, user, state, wait_type, wait_event, backend_start = line.split("\t")
        rows.append(
            {
                "application_name": app,
                "pid": int(pid),
                "user": user,
                "state": state,
                "wait_event_type": wait_type,
                "wait_event": wait_event,
                "backend_start": backend_start,
            }
        )

payload = {
    "captured_at_epoch": time.time(),
    "supervisor_pid": int(supervisor),
    "supervisor_start_ticks": start_ticks(supervisor),
    "token": token,
    "generation": generation,
    "replica_count": replica_count,
    "pool_size": pool_size,
    "replicas": states,
    "backend_rows": rows,
    "backend_pids": sorted(item["pid"] for item in rows),
    "processed_total": sum(int(item.get("processed_events", 0)) for item in states),
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
chmod 600 "$TRUST_ROOT/trust.json" "$activity"
echo "A_TRUST_CAPTURED=1 SUPERVISOR_PID=$supervisor TRUST=$TRUST_ROOT/trust.json"
