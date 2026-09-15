#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

fail() {
  echo "PEER_OK=0 REASON=$1"
  exit 1
}

[ -s "$TRUST_ROOT/a.json" ] || fail trust_missing
processes="$TRUST_ROOT/processes.current.tsv"
: > "$processes"
IFS=',' read -r -a replicas <<< "$REPLICA_NAMES"
for replica in "${replicas[@]}"; do
  [ -s "$SERVICE_ROOT/$replica.pid" ] || fail "${replica}_pid_missing"
  pid=$(cat "$SERVICE_ROOT/$replica.pid")
  kill -0 "$pid" 2>/dev/null || fail "${replica}_process_missing"
  ticks=$(awk '{print $22}' "/proc/$pid/stat")
  printf '%s\t%s\t%s\n' "$replica" "$pid" "$ticks" >> "$processes"
done

activity="$TRUST_ROOT/activity.current.tsv"
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT application_name, pid,
          to_char(backend_start AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US'), state
   FROM pg_stat_activity
   WHERE application_name LIKE 'document-index/%'
   ORDER BY application_name" > "$activity" || fail activity_query_failed

db_progress="$TRUST_ROOT/progress.current.tsv"
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" \
  --no-password --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT replica, coalesce(sum(commits), 0), coalesce(sum(documents_indexed), 0)
   FROM replica_progress GROUP BY replica ORDER BY replica" > "$db_progress" \
  || fail progress_query_failed

set +e
summary=$(/usr/bin/python3 - "$TRUST_ROOT/a.json" "$SERVICE_ROOT" "$processes" \
  "$activity" "$db_progress" 2>"$TRUST_ROOT/peer_check_python.stderr" <<'PY'
import json
import pathlib
import sys
import time

trust_path, service_root, process_path, activity_path, progress_path = sys.argv[1:]
trust = json.load(open(trust_path))
processes = {}
for line in pathlib.Path(process_path).read_text().splitlines():
    replica, pid, ticks = line.split("\t")
    processes[replica] = {"pid": int(pid), "start_ticks": int(ticks)}
activity = []
for line in pathlib.Path(activity_path).read_text().splitlines():
    if line.strip():
        app, pid, started, state = line.split("\t")
        activity.append({"application_name": app, "pid": int(pid), "backend_start": started, "state": state})
db_progress = {}
for line in pathlib.Path(progress_path).read_text().splitlines():
    replica, commits, documents = line.split("\t")
    db_progress[replica] = {"commits": int(commits), "documents": int(documents)}

assert sorted(processes) == sorted(trust["replica_names"]), "replica_process_roster_changed"
assert sorted(db_progress) == sorted(trust["replica_names"]), "replica_progress_roster_changed"
total_commits = 0
total_documents = 0
for replica in trust["replica_names"]:
    original = trust["replicas"][replica]
    current_process = processes[replica]
    state = json.load(open(pathlib.Path(service_root) / f"{replica}.json"))
    assert current_process["pid"] == original["pid"], f"{replica}_pid_changed"
    assert current_process["start_ticks"] == original["start_ticks"], f"{replica}_process_replaced"
    assert state["pid"] == original["pid"], f"{replica}_state_pid_changed"
    assert state["phase"] == "running", f"{replica}_not_running"
    assert state["instance_token"] == original["instance_token"], f"{replica}_token_changed"
    assert state["generation"] == trust["generation"], f"{replica}_generation_changed"
    assert state["pool_size"] == state["healthy_workers"] == trust["pool_per_replica"], f"{replica}_pool_unhealthy"
    assert time.time() - state["updated_at_epoch"] <= 5, f"{replica}_state_stale"
    expected = {
        (row["application_name"], row["pid"], row["backend_start"])
        for row in original["backend_roster"]
    }
    current_rows = [row for row in activity if row["application_name"].split("/")[1] == replica]
    actual = {(row["application_name"], row["pid"], row["backend_start"]) for row in current_rows}
    assert actual == expected, f"{replica}_backend_roster_changed"
    assert state["total_commits"] > original["total_commits"], f"{replica}_file_progress_not_advanced"
    assert db_progress[replica]["commits"] > original["db_commits"], f"{replica}_database_progress_not_advanced"
    total_commits += int(state["total_commits"])
    total_documents += int(state["documents_indexed"])

assert len(activity) == trust["aggregate_backends"], "aggregate_backend_count_changed"
print(total_commits, total_documents, len(activity), len(trust["replica_names"]))
PY
)
rc=$?
set -e
[ "$rc" = 0 ] || fail identity_or_progress_check_failed
read -r commits documents backends replica_count <<< "$summary"
health=$(psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" \
  --no-password --tuples-only --no-align --command \
  "SELECT current_database() || ':' || current_user || ':' || count(*) FROM source_documents") \
  || fail database_unhealthy
[ "$health" = "$PG_DATABASE:$PG_SUPERUSER:20000" ] || fail database_health_wrong
echo "PEER_OK=1 REPLICAS=$replica_count BACKENDS=$backends COMMITS=$commits DOCUMENTS=$documents GENERATION=$SERVICE_GENERATION"
