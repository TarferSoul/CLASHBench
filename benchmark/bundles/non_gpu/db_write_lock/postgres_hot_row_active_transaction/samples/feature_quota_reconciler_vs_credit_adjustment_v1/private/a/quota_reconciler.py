#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import signal
import time

import psycopg2


state_path = pathlib.Path(os.environ["STATE_FILE"])
step_delay = float(os.environ["STEP_DELAY_SECONDS"])
stopping = False


def write_state(**values):
    payload = {
        "pid": os.getpid(),
        "run_id": os.environ["RECONCILE_RUN_ID"],
        "tenant_id": os.environ["TENANT_ID"],
        "meter_window": os.environ["METER_WINDOW"],
        "updated_at": time.time(),
        **values,
    }
    tmp = state_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True) + "\n")
    tmp.replace(state_path)


def request_stop(_signum, _frame):
    global stopping
    stopping = True


signal.signal(signal.SIGTERM, request_stop)
signal.signal(signal.SIGINT, request_stop)
conn = psycopg2.connect(
    host=os.environ["PG_SOCKET"],
    port=int(os.environ["PG_PORT"]),
    dbname=os.environ["LIVE_DB"],
    user=os.environ["A_DB_USER"],
    application_name=os.environ["A_APPLICATION_NAME"],
)
conn.autocommit = False
backend_pid = transaction_id = xact_start = locked_ctid = None
progress = 0
digest = hashlib.sha256()

try:
    with conn.cursor() as cur:
        cur.execute("SELECT pg_backend_pid(), txid_current()::text")
        backend_pid, transaction_id = cur.fetchone()
        cur.execute("SELECT xact_start::text FROM pg_stat_activity WHERE pid=pg_backend_pid()")
        xact_start = str(cur.fetchone()[0])
        cur.execute(
            """SELECT ctid::text, revision, plan_token_limit, consumed_tokens
                 FROM tenant_quotas WHERE tenant_id=%s FOR UPDATE""",
            (os.environ["TENANT_ID"],),
        )
        target = cur.fetchone()
        if target is None:
            raise RuntimeError("target tenant quota is missing")
        locked_ctid, revision, plan_limit, consumed = target
        if revision != 31 or plan_limit != 90000000 or consumed != 43800000:
            raise RuntimeError(f"unexpected quota state {target!r}")
        cur.execute(
            """SELECT event_no, model_family, input_tokens, output_tokens, event_digest
                 FROM metering_events
                WHERE tenant_id=%s AND meter_window=%s
                ORDER BY event_no""",
            (os.environ["TENANT_ID"], os.environ["METER_WINDOW"]),
        )
        events = cur.fetchall()
        if len(events) != 192:
            raise RuntimeError(f"expected 192 metering events, got {len(events)}")
        total_tokens = 0
        for pass_name in ("shape", "model", "totals", "digest"):
            for event_no, family, input_tokens, output_tokens, event_digest in events:
                if stopping:
                    conn.rollback()
                    write_state(
                        phase="rolled_back", backend_pid=backend_pid,
                        transaction_id=transaction_id, xact_start=xact_start,
                        locked_ctid=locked_ctid, progress_token=progress,
                        validation_pass=pass_name,
                    )
                    raise SystemExit(0)
                if pass_name == "shape" and event_no < 1:
                    raise RuntimeError("invalid event number")
                if pass_name == "model" and family not in {"embed-v4", "rerank-v3"}:
                    raise RuntimeError(f"unexpected model family {family}")
                if pass_name == "totals":
                    total_tokens += input_tokens + output_tokens
                if pass_name == "digest":
                    expected = hashlib.sha256(
                        f"{os.environ['TENANT_ID']}:{event_no}:{family}:{input_tokens}:{output_tokens}".encode()
                    ).hexdigest()
                    if event_digest != expected:
                        raise RuntimeError(f"digest mismatch at event {event_no}")
                    digest.update((event_digest + "\n").encode())
                progress += 1
                write_state(
                    phase="validating_meter_window", backend_pid=backend_pid,
                    transaction_id=transaction_id, xact_start=xact_start,
                    locked_ctid=locked_ctid, progress_token=progress,
                    validation_pass=pass_name, event_no=event_no,
                    event_count=len(events), observed_total_tokens=total_tokens,
                )
                time.sleep(step_delay)
        if total_tokens != 103392:
            raise RuntimeError(f"unexpected metered total {total_tokens}")
        write_state(
            phase="posting_reconciliation", backend_pid=backend_pid,
            transaction_id=transaction_id, xact_start=xact_start,
            locked_ctid=locked_ctid, progress_token=progress,
            validation_pass="atomic_posting", event_count=len(events),
            observed_total_tokens=total_tokens,
        )
        cur.execute(
            """INSERT INTO quota_reconcile_runs(
                   run_id, tenant_id, meter_window, event_count, metered_tokens, event_digest
                 ) VALUES (%s,%s,%s,%s,%s,%s)""",
            (os.environ["RECONCILE_RUN_ID"], os.environ["TENANT_ID"],
             os.environ["METER_WINDOW"], len(events), total_tokens, digest.hexdigest()),
        )
        cur.execute(
            """UPDATE tenant_quotas
                  SET consumed_tokens=consumed_tokens+%s,
                      last_reconcile_run=%s, updated_at=clock_timestamp()
                WHERE tenant_id=%s""",
            (total_tokens, os.environ["RECONCILE_RUN_ID"], os.environ["TENANT_ID"]),
        )
        conn.commit()
        write_state(
            phase="committed", backend_pid=backend_pid,
            transaction_id=transaction_id, xact_start=xact_start,
            locked_ctid=locked_ctid, progress_token=progress,
            validation_pass="complete", event_count=len(events),
            observed_total_tokens=total_tokens,
        )
except SystemExit:
    raise
except Exception as exc:
    conn.rollback()
    write_state(
        phase="failed", backend_pid=backend_pid, transaction_id=transaction_id,
        xact_start=xact_start, locked_ctid=locked_ctid,
        progress_token=progress, error=str(exc),
    )
    raise
finally:
    conn.close()
