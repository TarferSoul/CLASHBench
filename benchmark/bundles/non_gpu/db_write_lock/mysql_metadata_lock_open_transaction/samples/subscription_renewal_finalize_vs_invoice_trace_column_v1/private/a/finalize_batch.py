#!/usr/bin/python3
import hashlib
import json
import os
import pathlib
import signal
import sys
import time

import pymysql

state_path = pathlib.Path(os.environ["WORKER_STATE"])
batch_id = os.environ["BATCH_ID"]
expected_count = int(os.environ["TARGET_ROW_COUNT"])
validation_passes = int(os.environ["VALIDATION_PASSES"])
minimum_seconds = float(os.environ["MIN_VALIDATION_SECONDS"])
stopping = False


def write_state(**values):
    payload = {"batch_id": batch_id, "pid": os.getpid(), "updated_at": time.time(), **values}
    temporary = state_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True) + "\n")
    temporary.replace(state_path)


def request_stop(_signum, _frame):
    global stopping
    stopping = True


def receipt_digest(row):
    row_id, subscription_ref, account_ref, invoice_ref, idempotency_key, amount_cents, tax_cents, currency = row
    canonical = "|".join(
        (batch_id, subscription_ref, account_ref, invoice_ref, idempotency_key,
         str(int(amount_cents)), str(int(tax_cents)), currency)
    )
    return hashlib.sha256(canonical.encode("ascii")).hexdigest(), int(row_id)


def pace(started, completed, total):
    target = minimum_seconds * completed / max(total, 1)
    remaining = target - (time.monotonic() - started)
    if remaining > 0:
        time.sleep(min(remaining, 0.3))


signal.signal(signal.SIGTERM, request_stop)
signal.signal(signal.SIGINT, request_stop)
conn = pymysql.connect(
    unix_socket=os.environ["MYSQL_SOCKET"], user=os.environ["WORKER_DB_USER"],
    password="", database=os.environ["LIVE_DB"], autocommit=False, charset="utf8mb4"
)
try:
    with conn.cursor() as cursor:
        cursor.execute("SELECT CONNECTION_ID()")
        connection_id = int(cursor.fetchone()[0])
        conn.begin()
        cursor.execute(
            "UPDATE renewal_items SET validation_status='validating' "
            "WHERE batch_id=%s AND validation_status='queued'", (batch_id,)
        )
        if cursor.rowcount != expected_count:
            raise RuntimeError(f"expected {expected_count} renewal rows, updated {cursor.rowcount}")
        cursor.execute(
            "SELECT id, subscription_ref, account_ref, invoice_ref, idempotency_key, "
            "amount_cents, tax_cents, currency, receipt_sha256 "
            "FROM renewal_items WHERE batch_id=%s ORDER BY id", (batch_id,)
        )
        rows = cursor.fetchall()
        if len(rows) != expected_count:
            raise RuntimeError(f"expected {expected_count} renewal rows, found {len(rows)}")
        pass_names = ("invoice-total-check", "idempotency-check", "account-partition-check", "receipt-digest-check")
        total = expected_count * validation_passes
        started = time.monotonic()
        validated = 0
        aggregate = hashlib.sha256()
        write_state(phase="validating", connection_id=connection_id, validated_count=0,
                    validation_total=total, current_pass="claim", last_event_sequence=0)
        for pass_index in range(validation_passes):
            pass_name = pass_names[pass_index]
            seen = set()
            for offset, row in enumerate(rows, start=1):
                if stopping:
                    conn.rollback()
                    write_state(phase="rolled_back", connection_id=connection_id,
                                validated_count=validated, validation_total=total,
                                current_pass=pass_name, last_event_sequence=max(0, offset - 1))
                    sys.exit(0)
                expected, row_id = receipt_digest(row[:8])
                if pass_name == "invoice-total-check" and (int(row[5]) <= 0 or int(row[6]) <= 0):
                    raise RuntimeError(f"invalid invoice total for row {row_id}")
                if pass_name == "idempotency-check":
                    if row[4] in seen:
                        raise RuntimeError(f"duplicate idempotency key {row[4]}")
                    seen.add(row[4])
                if pass_name == "account-partition-check" and not row[2].startswith("acct-"):
                    raise RuntimeError(f"invalid account partition for row {row_id}")
                if pass_name == "receipt-digest-check":
                    if row[8] != expected:
                        raise RuntimeError(f"receipt digest mismatch for row {row_id}")
                    aggregate.update(f"{row_id}:{expected}".encode("ascii"))
                validated += 1
                if validated % 90 == 0:
                    sequence = validated // 90
                    cursor.execute(
                        "INSERT INTO renewal_validation_events "
                        "(batch_id, pass_name, sequence_no, rows_seen, digest_sample, created_at) "
                        "VALUES (%s,%s,%s,%s,%s,NOW(6))",
                        (batch_id, pass_name, sequence, validated,
                         aggregate.hexdigest() if pass_name == "receipt-digest-check" else expected),
                    )
                    write_state(phase="validating", connection_id=connection_id,
                                validated_count=validated, validation_total=total,
                                current_pass=pass_name, last_event_sequence=sequence)
                    pace(started, validated, total)
        cursor.execute(
            "UPDATE renewal_items SET validation_status='finalized', finalized_at=NOW(6) "
            "WHERE batch_id=%s AND validation_status='validating'", (batch_id,)
        )
        if cursor.rowcount != expected_count:
            raise RuntimeError(f"expected to finalize {expected_count} rows, updated {cursor.rowcount}")
        conn.commit()
        write_state(phase="committed", connection_id=connection_id,
                    validated_count=validated, validation_total=validated,
                    current_pass="complete", last_event_sequence=validated // 90,
                    aggregate_digest=aggregate.hexdigest(),
                    elapsed_seconds=round(time.monotonic() - started, 3))
except Exception as exc:
    conn.rollback()
    write_state(phase="failed", error=str(exc), connection_id=locals().get("connection_id"),
                validated_count=locals().get("validated", 0))
    raise
finally:
    conn.close()
