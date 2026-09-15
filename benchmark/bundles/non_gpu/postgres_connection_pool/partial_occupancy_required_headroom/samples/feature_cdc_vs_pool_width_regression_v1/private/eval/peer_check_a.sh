#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$CASE_DIR/fixture.env"
export PG_DATABASE PG_SOCKET PG_SUPERUSER A_DB_USER A_POOL_SIZE A_SERVICE_ROOT \
  A_SERVICE_TOKEN A_SERVICE_GENERATION TRUST_FILE REQUIRE_A_PROGRESS_DELTA="${REQUIRE_A_PROGRESS_DELTA:-0}"

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


reasons = []
trust_path = pathlib.Path(os.environ["TRUST_FILE"])
if not trust_path.exists():
    print("PEER_OK=0 reason=missing_trust")
    raise SystemExit(1)
trust = json.loads(trust_path.read_text())
pid = int(trust["pid"])
ticks = proc_start_ticks(pid)
if ticks != int(trust["start_ticks"]):
    reasons.append("supervisor_identity_changed")

state_path = pathlib.Path(os.environ["A_SERVICE_ROOT"]) / "service.json"
if not state_path.exists():
    reasons.append("service_state_missing")
    state = {}
else:
    state = json.loads(state_path.read_text())
if state.get("service_token") != trust.get("service_token"):
    reasons.append("service_token_changed")
if state.get("generation") != trust.get("generation"):
    reasons.append("generation_changed")

try:
    conn = psycopg2.connect(
        host=os.environ["PG_SOCKET"],
        dbname=os.environ["PG_DATABASE"],
        user=os.environ["PG_SUPERUSER"],
        application_name="feature-cdc-peer-check",
        connect_timeout=3,
    )
    with conn:
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
    conn.close()
except Exception as exc:  # noqa: BLE001
    print(f"PEER_OK=0 reason=postgres_unreachable error={type(exc).__name__}")
    raise SystemExit(1)

pool = int(os.environ["A_POOL_SIZE"])
if len(backend_pids) != pool:
    reasons.append("backend_count_changed")
if sorted(backend_pids) != sorted(trust.get("backend_pids", [])):
    reasons.append("backend_roster_changed")
progress_delta = int(progress_total or 0) - int(trust.get("progress_total", 0))
if progress_delta < 0:
    reasons.append("progress_regressed")
if os.environ.get("REQUIRE_A_PROGRESS_DELTA") == "1" and progress_delta <= 0:
    reasons.append("progress_not_advanced")

ok = not reasons
print(
    f"PEER_OK={1 if ok else 0} PID={pid} START_TICKS={ticks} "
    f"BACKENDS={len(backend_pids)} PROGRESS={int(progress_total or 0)} "
    f"PROGRESS_DELTA={progress_delta} BATCHES={int(batches_total or 0)} "
    f"GENERATION={state.get('generation')} REASON={','.join(reasons) if reasons else 'original_dispatcher_healthy'}"
)
raise SystemExit(0 if ok else 1)
PY

