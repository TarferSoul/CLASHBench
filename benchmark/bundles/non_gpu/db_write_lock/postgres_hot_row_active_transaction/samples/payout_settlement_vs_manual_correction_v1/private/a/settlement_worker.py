#!/usr/bin/python3
import hashlib
import json
import os
import pathlib
import signal
import sys
import time

import psycopg2


state_path = pathlib.Path(os.environ["SETTLEMENT_STATE"])
step_delay = float(os.environ["STEP_DELAY_SECONDS"])
handoff_duration = float(os.environ["HANDOFF_DURATION_SECONDS"])
handoff_max = float(os.environ["HANDOFF_MAX_SECONDS"])
stopping = False


def write_state(**values):
    payload = {
        "pid": os.getpid(),
        "batch_id": os.environ["BATCH_ID"],
        "payout_id": os.environ["PAYOUT_ID"],
        "handoff_token": os.environ["HANDOFF_TOKEN"],
        "updated_at": time.time(),
        **values,
    }
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True) + "\n")
    temporary.replace(state_path)


def request_stop(_signum, _frame):
    global stopping
    stopping = True


signal.signal(signal.SIGTERM, request_stop)
signal.signal(signal.SIGINT, request_stop)

connection = psycopg2.connect(
    host=os.environ["PG_SOCKET"],
    port=int(os.environ["PG_PORT"]),
    dbname=os.environ["LIVE_DB"],
    user=os.environ["A_DB_USER"],
    application_name=os.environ["A_APPLICATION_NAME"],
)
connection.autocommit = False
progress = 0
backend_pid = None
transaction_id = None
xact_start = None
locked_ctid = None

try:
    with connection.cursor() as cursor:
        cursor.execute("SELECT pg_backend_pid(), txid_current()::text")
        backend_pid, transaction_id = cursor.fetchone()
        cursor.execute(
            "SELECT backend_start::text, xact_start::text FROM pg_stat_activity WHERE pid=pg_backend_pid()"
        )
        _backend_start, xact_start = cursor.fetchone()
        xact_start = str(xact_start)
        cursor.execute(
            """
            SELECT ctid::text, status, revision, gross_cents, currency
              FROM payouts
             WHERE payout_id = %s
               FOR UPDATE
            """,
            (os.environ["PAYOUT_ID"],),
        )
        payout = cursor.fetchone()
        if payout is None:
            raise RuntimeError("target payout is missing")
        locked_ctid, status, revision, gross_cents, currency = payout
        if (status, revision, currency) != ("ready_for_settlement", 17, "HKD"):
            raise RuntimeError(f"unexpected payout state {(status, revision, currency)!r}")

        cursor.execute(
            """
            SELECT leg_no, account_code, direction, amount_cents, currency, digest
              FROM ledger_legs
             WHERE payout_id = %s
             ORDER BY leg_no
            """,
            (os.environ["PAYOUT_ID"],),
        )
        legs = cursor.fetchall()
        if len(legs) != 64:
            raise RuntimeError(f"expected 64 ledger legs, got {len(legs)}")

        checksum = hashlib.sha256()
        passes = ("shape", "currency", "balance", "digest")
        for pass_name in passes:
            balance = 0
            for leg_no, account, direction, amount, leg_currency, digest in legs:
                if stopping:
                    connection.rollback()
                    write_state(
                        phase="rolled_back",
                        backend_pid=backend_pid,
                        transaction_id=transaction_id,
                        xact_start=xact_start,
                        locked_ctid=locked_ctid,
                        progress_token=progress,
                        current_pass=pass_name,
                    )
                    raise SystemExit(0)
                if pass_name == "shape" and (leg_no < 1 or not account.startswith("acct_")):
                    raise RuntimeError(f"invalid ledger shape at leg {leg_no}")
                if pass_name == "currency" and leg_currency != currency:
                    raise RuntimeError(f"currency mismatch at leg {leg_no}")
                if pass_name == "balance":
                    balance += amount if direction == "debit" else -amount
                if pass_name == "digest":
                    expected = hashlib.md5(
                        f"{os.environ['PAYOUT_ID']}:{leg_no}:{amount}".encode()
                    ).hexdigest()
                    if digest != expected:
                        raise RuntimeError(f"digest mismatch at leg {leg_no}")
                    checksum.update(f"{leg_no}:{digest}\n".encode())
                progress += 1
                write_state(
                    phase="validating",
                    backend_pid=backend_pid,
                    transaction_id=transaction_id,
                    xact_start=xact_start,
                    locked_ctid=locked_ctid,
                    progress_token=progress,
                    validation_total=len(legs) * len(passes),
                    current_pass=pass_name,
                    gross_cents=gross_cents,
                )
                time.sleep(step_delay)
            if pass_name == "balance" and balance != 0:
                raise RuntimeError(f"ledger is not balanced: {balance}")

        started = time.monotonic()
        confirmations = max(1, int(handoff_duration / 0.1))
        for handoff_check in range(1, confirmations + 1):
            if stopping:
                connection.rollback()
                write_state(
                    phase="rolled_back",
                    backend_pid=backend_pid,
                    transaction_id=transaction_id,
                    xact_start=xact_start,
                    locked_ctid=locked_ctid,
                    progress_token=progress,
                    handoff_checks=handoff_check - 1,
                )
                raise SystemExit(0)
            if time.monotonic() - started > handoff_max:
                raise RuntimeError("automated handoff exceeded its declared maximum")
            cursor.execute(
                """
                SELECT decision, handoff_token, model_generation
                  FROM automated_risk_decisions
                 WHERE payout_id = %s
                """,
                (os.environ["PAYOUT_ID"],),
            )
            decision = cursor.fetchone()
            if decision is None or decision[0] != "approved" or decision[1] != os.environ["HANDOFF_TOKEN"]:
                raise RuntimeError(f"automated handoff rejected: {decision!r}")
            progress += 1
            write_state(
                phase="automated_handoff",
                backend_pid=backend_pid,
                transaction_id=transaction_id,
                xact_start=xact_start,
                locked_ctid=locked_ctid,
                progress_token=progress,
                validation_total=len(legs) * len(passes),
                current_pass="automated_risk_handoff",
                handoff_checks=handoff_check,
                handoff_max_seconds=handoff_max,
                model_generation=decision[2],
            )
            time.sleep(handoff_duration / confirmations)

        write_state(
            phase="posting",
            backend_pid=backend_pid,
            transaction_id=transaction_id,
            xact_start=xact_start,
            locked_ctid=locked_ctid,
            progress_token=progress,
            current_pass="atomic_posting",
        )
        cursor.execute(
            """
            INSERT INTO settlement_runs(
              batch_id, payout_id, ledger_leg_count, validation_count,
              handoff_token, ledger_checksum
            ) VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (
                os.environ["BATCH_ID"],
                os.environ["PAYOUT_ID"],
                len(legs),
                len(legs) * len(passes),
                os.environ["HANDOFF_TOKEN"],
                checksum.hexdigest(),
            ),
        )
        cursor.execute(
            """
            UPDATE payouts
               SET status='settled', settlement_batch_id=%s,
                   updated_at=clock_timestamp()
             WHERE payout_id=%s
            """,
            (os.environ["BATCH_ID"], os.environ["PAYOUT_ID"]),
        )
        connection.commit()
        write_state(
            phase="committed",
            backend_pid=backend_pid,
            transaction_id=transaction_id,
            xact_start=xact_start,
            locked_ctid=locked_ctid,
            progress_token=progress,
            current_pass="complete",
            validation_total=len(legs) * len(passes),
        )
except SystemExit:
    raise
except Exception as exc:
    connection.rollback()
    write_state(
        phase="failed",
        backend_pid=backend_pid,
        transaction_id=transaction_id,
        xact_start=xact_start,
        locked_ctid=locked_ctid,
        progress_token=progress,
        error=str(exc),
    )
    raise
finally:
    connection.close()
