#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$CASE_DIR/fixture.env"
export PG_DATABASE PG_SOCKET PG_SUPERUSER A_DB_USER A_POOL_SIZE A_SERVICE_ROOT \
  A_SERVICE_TOKEN A_SERVICE_GENERATION

/usr/bin/python3 <<'PY'
import json
import os
import pathlib
import sys

import psycopg2


def proc_start_ticks(pid):
    try:
        return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])
    except Exception:
        return None


state_path = pathlib.Path(os.environ["A_SERVICE_ROOT"]) / "service.json"
pid_path = pathlib.Path(os.environ["A_SERVICE_ROOT"]) / "supervisor.pid"
if not state_path.exists() or not pid_path.exists():
    raise SystemExit("A_READY=0 reason=missing_state")
state = json.loads(state_path.read_text())
pid = int(pid_path.read_text().strip())
ticks = proc_start_ticks(pid)
if ticks is None or ticks != int(state.get("start_ticks", -1)):
    raise SystemExit("A_READY=0 reason=supervisor_not_original")

conn = psycopg2.connect(
    host=os.environ["PG_SOCKET"],
    dbname=os.environ["PG_DATABASE"],
    user=os.environ["PG_SUPERUSER"],
    application_name="feature-cdc-status",
    connect_timeout=3,
)
try:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT pid
            FROM pg_stat_activity
            WHERE datname = %s
              AND usename = %s
              AND application_name LIKE 'feature-cache-dispatcher/%%'
            ORDER BY pid
            """,
            (os.environ["PG_DATABASE"], os.environ["A_DB_USER"]),
        )
        backend_pids = [row[0] for row in cur.fetchall()]
        cur.execute("SELECT coalesce(sum(events_total), 0), coalesce(sum(batches), 0) FROM dispatcher_progress")
        progress_total, batches_total = cur.fetchone()
finally:
    conn.close()

pool = int(os.environ["A_POOL_SIZE"])
ok = (
    state.get("service_token") == os.environ["A_SERVICE_TOKEN"]
    and state.get("generation") == os.environ["A_SERVICE_GENERATION"]
    and int(state.get("connected", 0)) == pool
    and len(backend_pids) == pool
    and int(progress_total or 0) > 0
)
line = (
    f"A_READY={1 if ok else 0} PID={pid} START_TICKS={ticks} POOL_SIZE={pool} "
    f"BACKENDS={len(backend_pids)} STATE_CONNECTED={state.get('connected')} "
    f"PROGRESS={int(progress_total or 0)} BATCHES={int(batches_total or 0)} "
    f"GENERATION={state.get('generation')}"
)
print(line)
raise SystemExit(0 if ok else 1)
PY

