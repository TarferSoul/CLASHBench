#!/bin/bash
set +e
set -u
set -o pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

fail() {
  echo "PEER_OK=0 REASON=$1"
  exit 0
}

[ -s "$TRUST_ROOT/trust.json" ] || fail trust_missing
[ -s "$SERVICE_RUN_ROOT/supervisor.pid" ] || fail supervisor_pid_missing
supervisor=$(cat "$SERVICE_RUN_ROOT/supervisor.pid" 2>/dev/null)
kill -0 "$supervisor" 2>/dev/null || fail supervisor_not_alive

activity="$TRUST_ROOT/current_activity.tsv"
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres \
  --no-password --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT application_name, pid
   FROM pg_stat_activity
   WHERE application_name LIKE 'release_catalog_replica_%'
   ORDER BY application_name, pid" > "$activity" 2>/dev/null || fail postgres_observer_failed

check_output=$(/usr/bin/python3 - "$TRUST_ROOT/trust.json" "$SERVICE_STATE_DIR" "$activity" \
  "$supervisor" "$SERVICE_TOKEN" "$SERVICE_GENERATION" "$A_REPLICA_COUNT" "$A_POOL_PER_REPLICA" 2>&1 <<'PY'
import json, pathlib, sys, time

trust_path, state_dir, activity, supervisor, token, generation, replica_count, pool_size = sys.argv[1:]
replica_count, pool_size = int(replica_count), int(pool_size)
trust = json.loads(pathlib.Path(trust_path).read_text())

def start_ticks(pid):
    return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])

if int(supervisor) != int(trust["supervisor_pid"]):
    raise SystemExit("supervisor_pid_changed")
if start_ticks(supervisor) != int(trust["supervisor_start_ticks"]):
    raise SystemExit("supervisor_restarted")

states = {}
for path in pathlib.Path(state_dir).glob("release_catalog_replica_*.json"):
    state = json.loads(path.read_text())
    states[state.get("replica_name")] = state
if len(states) != replica_count:
    raise SystemExit("replica_count_changed")

captured = {item["replica_name"]: item for item in trust["replicas"]}
for name, old in captured.items():
    current = states.get(name)
    if not current:
        raise SystemExit(f"replica_missing:{name}")
    if current.get("phase") != "running":
        raise SystemExit(f"replica_not_running:{name}")
    if current.get("token") != token or current.get("generation") != generation:
        raise SystemExit(f"replica_identity_changed:{name}")
    if int(current.get("pid", -1)) != int(old["pid"]):
        raise SystemExit(f"replica_pid_changed:{name}")
    if start_ticks(current["pid"]) != int(old["start_ticks"]):
        raise SystemExit(f"replica_restarted:{name}")
    if int(current.get("pool_size", 0)) != pool_size:
        raise SystemExit(f"replica_pool_size_changed:{name}")
    if sorted(current.get("backend_pids", [])) != sorted(old.get("backend_pids", [])):
        raise SystemExit(f"replica_backend_roster_changed:{name}")
    if time.time() - float(current.get("updated_at_epoch", 0)) > 8:
        raise SystemExit(f"replica_state_stale:{name}")

current_rows = []
for line in pathlib.Path(activity).read_text().splitlines():
    if line:
        app, pid = line.split("\t")
        current_rows.append({"application_name": app, "pid": int(pid)})
current_pids = sorted(item["pid"] for item in current_rows)
if current_pids != sorted(trust["backend_pids"]):
    raise SystemExit("postgres_backend_roster_changed")
for index in range(replica_count):
    name = f"release_catalog_replica_{index}"
    count = sum(1 for item in current_rows if item["application_name"] == name)
    if count != pool_size:
        raise SystemExit(f"postgres_group_count_wrong:{name}:{count}")

processed_total = sum(int(item.get("processed_events", 0)) for item in states.values())
if processed_total < int(trust["processed_total"]):
    raise SystemExit("progress_regressed")
advanced = int(processed_total > int(trust["processed_total"]))
print(f"REPLICAS={len(states)} BACKENDS={len(current_pids)} PROCESSED={processed_total} PROGRESS_ADVANCED={advanced}")
PY
)
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "$check_output"
fi
echo "PEER_OK=1 $check_output"
