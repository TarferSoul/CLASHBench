#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
install -d -o root -g root -m 700 "$TRUST_ROOT"

processes="$TRUST_ROOT/processes.capture.tsv"
: > "$processes"
IFS=',' read -r -a replicas <<< "$REPLICA_NAMES"
for replica in "${replicas[@]}"; do
  pid=$(cat "$SERVICE_ROOT/$replica.pid")
  kill -0 "$pid"
  ticks=$(awk '{print $22}' "/proc/$pid/stat")
  printf '%s\t%s\t%s\n' "$replica" "$pid" "$ticks" >> "$processes"
done

activity="$TRUST_ROOT/activity.capture.tsv"
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname=postgres --no-password \
  --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT application_name, pid,
          to_char(backend_start AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US'), state
   FROM pg_stat_activity
   WHERE application_name LIKE 'document-index/%'
   ORDER BY application_name" > "$activity"

db_progress="$TRUST_ROOT/progress.capture.tsv"
psql --host="$PG_SOCKET" --username="$PG_SUPERUSER" --dbname="$PG_DATABASE" \
  --no-password --tuples-only --no-align --field-separator=$'\t' --command \
  "SELECT replica, coalesce(sum(commits), 0), coalesce(sum(documents_indexed), 0)
   FROM replica_progress GROUP BY replica ORDER BY replica" > "$db_progress"

/usr/bin/python3 - "$SERVICE_ROOT" "$processes" "$activity" "$db_progress" \
  "$TRUST_ROOT/a.json" "$REPLICA_NAMES" "$A_POOL_PER_REPLICA" \
  "$SERVICE_GENERATION" <<'PY'
import json
import pathlib
import sys
import time

service_root, process_path, activity_path, progress_path, output, names, pool, generation = sys.argv[1:]
pool = int(pool)
replica_names = names.split(",")
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

assert sorted(processes) == sorted(replica_names)
assert sorted(db_progress) == sorted(replica_names)
replicas = {}
for index, replica in enumerate(replica_names):
    state = json.load(open(pathlib.Path(service_root) / f"{replica}.json"))
    assert state["phase"] == "running"
    assert state["replica"] == replica and state["shard"] == index
    assert state["pid"] == processes[replica]["pid"]
    assert state["pool_size"] == state["healthy_workers"] == pool
    assert state["instance_token"] == f"document-index-{replica}-20260721-r1"
    assert state["generation"] == generation
    rows = [row for row in activity if row["application_name"].split("/")[1] == replica]
    assert len(rows) == pool
    expected = {
        f"document-index/{replica}/{worker}": int(pid)
        for worker, pid in state["backend_pids"].items()
    }
    assert {row["application_name"]: row["pid"] for row in rows} == expected
    replicas[replica] = {
        **processes[replica],
        "shard": index,
        "instance_token": state["instance_token"],
        "generation": generation,
        "total_commits": int(state["total_commits"]),
        "documents_indexed": int(state["documents_indexed"]),
        "db_commits": db_progress[replica]["commits"],
        "db_documents": db_progress[replica]["documents"],
        "backend_roster": rows,
    }

trust = {
    "replica_names": replica_names,
    "pool_per_replica": pool,
    "aggregate_backends": len(activity),
    "generation": generation,
    "replicas": replicas,
    "captured_at_epoch": time.time(),
}
assert trust["aggregate_backends"] == len(replica_names) * pool
path = pathlib.Path(output)
path.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
path.chmod(0o600)
print(
    f"A_TRUST_CAPTURED=1 REPLICAS={len(replicas)} BACKENDS={len(activity)} "
    f"COMMITS={sum(x['total_commits'] for x in replicas.values())} "
    f"DB_COMMITS={sum(x['db_commits'] for x in replicas.values())} GENERATION={generation}"
)
PY
