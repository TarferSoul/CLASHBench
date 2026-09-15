#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
set -a
. "$ROOT/fixture.env"
set +a
SNAPSHOT=${A_STATUS_SNAPSHOT:-}
WAIT_LOOPS=${A_STATUS_WAIT_LOOPS:-80}

collect_once() {
  /usr/bin/python3 - "$SNAPSHOT" <<'PY'
import csv
import json
import os
import pathlib
import subprocess
import sys
import time

snapshot_path = sys.argv[1]
env = os.environ


def proc_start_ticks(pid):
    try:
        text = pathlib.Path(f"/proc/{pid}/stat").read_text()
        after = text.rsplit(") ", 1)[1].split()
        return int(after[19])
    except Exception:
        return None


def run_psql(sql):
    proc = subprocess.run(
        [
            "psql",
            "--host", env["PG_SOCKET"],
            "--username", env["PG_SUPERUSER"],
            "--dbname", "postgres",
            "--no-password",
            "--tuples-only",
            "--no-align",
            "--field-separator", "\t",
            "--command", sql,
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        return [], proc.stderr.strip()
    rows = []
    for row in csv.reader(proc.stdout.splitlines(), delimiter="\t"):
        if row:
            rows.append(row)
    return rows, ""


pidfile = pathlib.Path(env["SERVICE_PIDFILE"])
supervisor_pid = int(pidfile.read_text().strip()) if pidfile.exists() else 0
supervisor_alive = supervisor_pid > 0 and pathlib.Path(f"/proc/{supervisor_pid}").exists()
supervisor_ticks = proc_start_ticks(supervisor_pid) if supervisor_alive else None
state_dir = pathlib.Path(env["A_STATE_DIR"])
output_dir = pathlib.Path(env["A_OUTPUT_DIR"])
supervisor_state_path = state_dir / "supervisor.json"
try:
    supervisor_state = json.loads(supervisor_state_path.read_text())
except Exception:
    supervisor_state = {}

prefix = env["A_APP_PREFIX"].replace("'", "''")
sql = f"""
SELECT application_name, pid, usename, datname, state,
       COALESCE(wait_event_type, ''), COALESCE(wait_event, ''),
       to_char(backend_start AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
       to_char(query_start AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
       to_char(xact_start AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US')
FROM pg_stat_activity
WHERE application_name LIKE '{prefix}%'
ORDER BY application_name
"""
activity, activity_error = run_psql(sql)
backends = []
for row in activity:
    if len(row) >= 10:
        backends.append(
            {
                "application_name": row[0],
                "pid": int(row[1]),
                "user": row[2],
                "database": row[3],
                "state": row[4],
                "wait_event_type": row[5],
                "wait_event": row[6],
                "backend_start": row[7],
                "query_start": row[8],
                "xact_start": row[9],
            }
        )

section_states = []
for path in sorted(state_dir.glob("partition_*.json")):
    try:
        item = json.loads(path.read_text())
    except Exception as exc:
        item = {"path": str(path), "error": f"{type(exc).__name__}:{exc}"}
    section_states.append(item)

files = []
for path in sorted(output_dir.glob("coverage_region_*.csv")):
    try:
        size = path.stat().st_size
    except OSError:
        size = 0
    files.append({"name": path.name, "bytes": size})

active_count = sum(1 for item in backends if item["state"] == "active")
total_bytes = sum(item["bytes"] for item in files)
sections_with_bytes = sum(1 for item in files if item["bytes"] >= int(env["A_READY_MIN_SECTION_BYTES"]))
expected = int(env["A_POOL_SIZE"])
ready = (
    supervisor_alive
    and supervisor_state.get("generation") == env["SERVICE_GENERATION"]
    and supervisor_state.get("service_token") == env["SERVICE_TOKEN"]
    and len(backends) == expected
    and active_count == expected
    and total_bytes >= int(env["A_READY_MIN_BYTES"])
    and sections_with_bytes >= max(8, expected // 2)
)
snapshot = {
    "ready": ready,
    "generation": supervisor_state.get("generation"),
    "service_token": supervisor_state.get("service_token"),
    "supervisor_pid": supervisor_pid,
    "supervisor_start_ticks": supervisor_ticks,
    "supervisor_alive": supervisor_alive,
    "worker_pids": supervisor_state.get("worker_pids", {}),
    "alive_workers": supervisor_state.get("alive_workers", []),
    "backend_count": len(backends),
    "active_backend_count": active_count,
    "backends": backends,
    "total_output_bytes": total_bytes,
    "sections_with_bytes": sections_with_bytes,
    "files": files,
    "section_states": section_states,
    "activity_error": activity_error,
    "captured_at_epoch": time.time(),
}
if snapshot_path:
    pathlib.Path(snapshot_path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(snapshot_path).write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n")
print(json.dumps(snapshot, sort_keys=True))
if not ready:
    raise SystemExit(1)
PY
}

last_rc=1
for _ in $(seq 1 "$WAIT_LOOPS"); do
  if output=$(collect_once 2>&1); then
    echo "A_OK=1 BACKENDS=$A_POOL_SIZE ACTIVE=$A_POOL_SIZE SNAPSHOT=${SNAPSHOT:-inline}"
    printf '%s\n' "$output"
    exit 0
  fi
  last_rc=$?
  sleep 0.25
done
echo "A_OK=0 REASON=not_ready SNAPSHOT=${SNAPSHOT:-inline}"
printf '%s\n' "$output" 2>/dev/null || true
exit "$last_rc"
