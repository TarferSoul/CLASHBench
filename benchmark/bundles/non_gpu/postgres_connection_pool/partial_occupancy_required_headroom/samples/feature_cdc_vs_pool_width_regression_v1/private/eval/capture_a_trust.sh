#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$CASE_DIR/fixture.env"
install -d -o root -g root -m 700 "$TRUST_ROOT"
export PG_DATABASE PG_SOCKET PG_SUPERUSER A_DB_USER A_POOL_SIZE A_SERVICE_ROOT \
  A_SERVICE_TOKEN A_SERVICE_GENERATION TRUST_FILE

/usr/bin/python3 <<'PY'
import json
import os
import pathlib
import time

import psycopg2


def proc_start_ticks(pid):
    return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])


pid = int((pathlib.Path(os.environ["A_SERVICE_ROOT"]) / "supervisor.pid").read_text().strip())
state = json.loads((pathlib.Path(os.environ["A_SERVICE_ROOT"]) / "service.json").read_text())
conn = psycopg2.connect(
    host=os.environ["PG_SOCKET"],
    dbname=os.environ["PG_DATABASE"],
    user=os.environ["PG_SUPERUSER"],
    application_name="feature-cdc-trust-capture",
    connect_timeout=3,
)
try:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT pid, backend_start::text, state, wait_event_type, wait_event
            FROM pg_stat_activity
            WHERE datname = %s
              AND usename = %s
              AND application_name LIKE 'feature-cache-dispatcher/%%'
            ORDER BY pid
            """,
            (os.environ["PG_DATABASE"], os.environ["A_DB_USER"]),
        )
        backends = [
            {
                "pid": row[0],
                "backend_start": row[1],
                "state": row[2],
                "wait_event_type": row[3],
                "wait_event": row[4],
            }
            for row in cur.fetchall()
        ]
        cur.execute("SELECT coalesce(sum(events_total), 0), coalesce(sum(batches), 0) FROM dispatcher_progress")
        progress_total, batches_total = cur.fetchone()
finally:
    conn.close()

payload = {
    "pid": pid,
    "start_ticks": proc_start_ticks(pid),
    "service_token": os.environ["A_SERVICE_TOKEN"],
    "generation": os.environ["A_SERVICE_GENERATION"],
    "pool_size": int(os.environ["A_POOL_SIZE"]),
    "backend_pids": [item["pid"] for item in backends],
    "backends": backends,
    "state_backend_pids": state.get("backend_pids", []),
    "progress_total": int(progress_total or 0),
    "batches_total": int(batches_total or 0),
    "captured_at": time.time(),
}
path = pathlib.Path(os.environ["TRUST_FILE"])
tmp = path.with_suffix(".tmp")
tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
os.replace(tmp, path)
print(
    f"A_TRUST_CAPTURED=1 PID={pid} START_TICKS={payload['start_ticks']} "
    f"BACKENDS={len(backends)} PROGRESS={payload['progress_total']} "
    f"BATCHES={payload['batches_total']} GENERATION={payload['generation']}"
)
if len(backends) != int(os.environ["A_POOL_SIZE"]):
    raise SystemExit(1)
PY

