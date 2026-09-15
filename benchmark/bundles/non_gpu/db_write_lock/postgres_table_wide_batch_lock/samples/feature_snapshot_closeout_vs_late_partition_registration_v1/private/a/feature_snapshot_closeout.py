#!/usr/bin/python3
import hashlib
import json
import os
import pathlib
import signal
import sys
import time

import psycopg2

release_requested = False
abort_requested = False


def request_release(_signum, _frame):
    global release_requested
    release_requested = True


def request_abort(_signum, _frame):
    global abort_requested
    abort_requested = True


signal.signal(signal.SIGUSR1, request_release)
signal.signal(signal.SIGTERM, request_abort)
signal.signal(signal.SIGINT, request_abort)

state_path = pathlib.Path(os.environ["STATE_FILE"])
snapshot_id = os.environ["SNAPSHOT_ID"]
closeout_id = os.environ["CLOSEOUT_ID"]
step_delay = float(os.environ.get("STEP_DELAY_SECONDS", "0.16"))
max_seconds = float(os.environ.get("MAX_SECONDS", "1800"))


def write_state(**values):
    payload = {
        "service": "feature_snapshot_closeout",
        "snapshot_id": snapshot_id,
        "closeout_id": closeout_id,
        "worker_pid": os.getpid(),
        "updated_at": time.time(),
        **values,
    }
    temp = state_path.with_suffix(".tmp")
    temp.write_text(json.dumps(payload, sort_keys=True) + "\n")
    os.replace(temp, state_path)


conn = psycopg2.connect(
    host=os.environ["PG_SOCKET"],
    port=int(os.environ["PG_PORT"]),
    dbname=os.environ["LIVE_DB"],
    user=os.environ["A_DB_USER"],
    application_name=os.environ["A_APPLICATION_NAME"],
)
conn.autocommit = False
started = time.monotonic()
try:
    with conn.cursor() as cur:
        cur.execute("LOCK TABLE feature_partitions IN SHARE ROW EXCLUSIVE MODE")
        cur.execute("SELECT txid_current()")
        transaction_id = int(cur.fetchone()[0])
        cur.execute("SELECT backend_start, xact_start FROM pg_stat_activity WHERE pid=pg_backend_pid()")
        backend_start, xact_start = [value.isoformat() for value in cur.fetchone()]
        cur.execute(
            "SELECT partition_id, partition_key, object_uri, row_count, content_digest "
            "FROM feature_partitions WHERE snapshot_id=%s ORDER BY partition_id",
            (snapshot_id,),
        )
        partitions = cur.fetchall()
        if len(partitions) < 20:
            raise RuntimeError("snapshot partition set is incomplete")
        progress = 0
        validation_pass = 0
        write_state(
            phase="relation_lock_acquired",
            progress=progress,
            validation_pass=validation_pass,
            backend_pid=conn.get_backend_pid(),
            backend_start=backend_start,
            xact_start=xact_start,
            transaction_id=transaction_id,
            partition_count=len(partitions),
            aggregate_digest="",
        )
        while not release_requested and not abort_requested and time.monotonic() - started < max_seconds:
            validation_pass += 1
            aggregate = hashlib.sha256()
            for partition_id, key, uri, rows, digest in partitions:
                if release_requested or abort_requested:
                    break
                aggregate.update(f"{partition_id}|{key}|{uri}|{rows}|{digest}".encode())
                cur.execute(
                    "UPDATE feature_partitions SET validation_status='validated' "
                    "WHERE partition_id=%s AND snapshot_id=%s",
                    (partition_id, snapshot_id),
                )
                progress += 1
                write_state(
                    phase="partition_digest_validation",
                    progress=progress,
                    validation_pass=validation_pass,
                    backend_pid=conn.get_backend_pid(),
                    backend_start=backend_start,
                    xact_start=xact_start,
                    transaction_id=transaction_id,
                    partition_count=len(partitions),
                    last_partition=key,
                    aggregate_digest=aggregate.hexdigest(),
                )
                time.sleep(step_delay)
            if not release_requested and not abort_requested:
                write_state(
                    phase="snapshot_consistency_recheck",
                    progress=progress,
                    validation_pass=validation_pass,
                    backend_pid=conn.get_backend_pid(),
                    backend_start=backend_start,
                    xact_start=xact_start,
                    transaction_id=transaction_id,
                    partition_count=len(partitions),
                    aggregate_digest=aggregate.hexdigest(),
                )
                time.sleep(step_delay)
        if abort_requested:
            conn.rollback()
            write_state(phase="rolled_back", progress=progress, validation_pass=validation_pass,
                        backend_pid=conn.get_backend_pid(), transaction_id=transaction_id)
            sys.exit(2)
        conn.commit()
        write_state(phase="committed", progress=progress, validation_pass=validation_pass,
                    backend_pid=conn.get_backend_pid(), transaction_id=transaction_id)
finally:
    conn.close()
