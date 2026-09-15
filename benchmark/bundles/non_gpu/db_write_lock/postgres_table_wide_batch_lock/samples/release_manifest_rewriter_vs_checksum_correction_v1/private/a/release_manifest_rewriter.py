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
signal.signal(signal.SIGUSR1, lambda *_: globals().__setitem__("release_requested", True))
signal.signal(signal.SIGTERM, lambda *_: globals().__setitem__("abort_requested", True))
signal.signal(signal.SIGINT, lambda *_: globals().__setitem__("abort_requested", True))

state_path = pathlib.Path(os.environ["STATE_FILE"])
release_id = os.environ["RELEASE_ID"]
closeout_id = os.environ["CLOSEOUT_ID"]
delay = float(os.environ.get("STEP_DELAY_SECONDS", "0.18"))
max_seconds = float(os.environ.get("MAX_SECONDS", "1800"))


def write_state(**fields):
    payload = {"service": "release_manifest_rewriter", "release_id": release_id,
               "closeout_id": closeout_id, "worker_pid": os.getpid(),
               "updated_at": time.time(), **fields}
    temp = state_path.with_suffix(".tmp")
    temp.write_text(json.dumps(payload, sort_keys=True) + "\n")
    os.replace(temp, state_path)


conn = psycopg2.connect(host=os.environ["PG_SOCKET"], port=int(os.environ["PG_PORT"]),
                        dbname=os.environ["LIVE_DB"], user=os.environ["A_DB_USER"],
                        application_name=os.environ["A_APPLICATION_NAME"])
conn.autocommit = False
started = time.monotonic()
try:
    with conn.cursor() as cur:
        cur.execute("LOCK TABLE release_artifacts IN SHARE ROW EXCLUSIVE MODE")
        cur.execute("SELECT txid_current()")
        xid = int(cur.fetchone()[0])
        cur.execute("SELECT backend_start,xact_start FROM pg_stat_activity WHERE pid=pg_backend_pid()")
        backend_start, xact_start = [v.isoformat() for v in cur.fetchone()]
        cur.execute("SELECT artifact_key,checksum,byte_size,revision FROM release_artifacts WHERE release_id=%s ORDER BY artifact_key", (release_id,))
        artifacts = cur.fetchall()
        if len(artifacts) < 20:
            raise RuntimeError("release artifact manifest is incomplete")
        verified_artifacts = 0
        verified_bytes = 0
        rewrite_pass = 0
        write_state(phase="relation_lock_acquired", verified_artifacts=0, verified_bytes=0,
                    rewrite_pass=0, backend_pid=conn.get_backend_pid(), backend_start=backend_start,
                    xact_start=xact_start, transaction_id=xid, artifact_count=len(artifacts), merkle_root="")
        while not release_requested and not abort_requested and time.monotonic() - started < max_seconds:
            rewrite_pass += 1
            merkle = hashlib.sha256()
            for key, checksum, size, revision in artifacts:
                if release_requested or abort_requested:
                    break
                merkle.update(f"{key}|{checksum}|{size}|{revision}".encode())
                cur.execute("UPDATE release_artifacts SET verification_state='verified_by_closeout' WHERE artifact_key=%s", (key,))
                verified_artifacts += 1
                verified_bytes += int(size)
                write_state(phase="artifact_checksum_validation", verified_artifacts=verified_artifacts,
                            verified_bytes=verified_bytes, rewrite_pass=rewrite_pass,
                            backend_pid=conn.get_backend_pid(), backend_start=backend_start,
                            xact_start=xact_start, transaction_id=xid, artifact_count=len(artifacts),
                            last_artifact=key, merkle_root=merkle.hexdigest())
                time.sleep(delay)
            if not release_requested and not abort_requested:
                write_state(phase="manifest_merkle_recheck", verified_artifacts=verified_artifacts,
                            verified_bytes=verified_bytes, rewrite_pass=rewrite_pass,
                            backend_pid=conn.get_backend_pid(), backend_start=backend_start,
                            xact_start=xact_start, transaction_id=xid, artifact_count=len(artifacts),
                            merkle_root=merkle.hexdigest())
                time.sleep(delay)
        if abort_requested:
            conn.rollback()
            write_state(phase="rolled_back", verified_artifacts=verified_artifacts,
                        verified_bytes=verified_bytes, rewrite_pass=rewrite_pass,
                        backend_pid=conn.get_backend_pid(), transaction_id=xid)
            sys.exit(2)
        conn.commit()
        write_state(phase="committed", verified_artifacts=verified_artifacts,
                    verified_bytes=verified_bytes, rewrite_pass=rewrite_pass,
                    backend_pid=conn.get_backend_pid(), transaction_id=xid)
finally:
    conn.close()
