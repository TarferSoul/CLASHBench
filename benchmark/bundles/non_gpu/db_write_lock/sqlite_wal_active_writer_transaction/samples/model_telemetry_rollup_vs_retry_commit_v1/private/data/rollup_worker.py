#!/usr/bin/env python3
import argparse
import json
import os
import signal
import sqlite3
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--db", required=True)
parser.add_argument("--status", required=True)
parser.add_argument("--batch-id", required=True)
args = parser.parse_args()

release_requested = False

def request_publish(_signum, _frame):
    global release_requested
    release_requested = True

signal.signal(signal.SIGUSR1, request_publish)

def write_status(**fields):
    payload = {
        "pid": os.getpid(),
        "batch_id": args.batch_id,
        "updated_at": time.time(),
        **fields,
    }
    directory = os.path.dirname(args.status)
    fd, tmp = tempfile.mkstemp(prefix=".rollup-status-", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, args.status)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

conn = sqlite3.connect(args.db, timeout=1, isolation_level=None)
conn.execute("PRAGMA busy_timeout=1000")
conn.execute("PRAGMA foreign_keys=ON")
mode = conn.execute("PRAGMA journal_mode").fetchone()[0].lower()
if mode != "wal":
    raise SystemExit(f"expected WAL, got {mode}")

folded = 0
validation_passes = 0
try:
    conn.execute("BEGIN IMMEDIATE")
    while True:
        if folded < 96:
            row = conn.execute(
                "SELECT event_id,model,input_tokens,output_tokens,latency_ms "
                "FROM staged_events WHERE event_id=?",
                (folded + 1,),
            ).fetchone()
            event_id, model, input_tokens, output_tokens, latency_ms = row
            conn.execute(
                "INSERT INTO hourly_rollups(hour_bucket,model,request_count,input_tokens,output_tokens,latency_ms) "
                "VALUES ('2026-08-04T03:00Z',?,1,?,?,?) "
                "ON CONFLICT(hour_bucket,model) DO UPDATE SET "
                "request_count=request_count+1,input_tokens=input_tokens+excluded.input_tokens,"
                "output_tokens=output_tokens+excluded.output_tokens,latency_ms=latency_ms+excluded.latency_ms",
                (model, input_tokens, output_tokens, latency_ms),
            )
            folded = event_id
        else:
            request_count, token_total = conn.execute(
                "SELECT sum(request_count),sum(input_tokens+output_tokens) FROM hourly_rollups"
            ).fetchone()
            if request_count != 96 or token_total <= 0:
                raise RuntimeError("candidate rollup validation failed")
            validation_passes += 1
        progress_seq = folded + validation_passes
        write_status(
            phase="active",
            transaction="BEGIN IMMEDIATE",
            journal_mode=mode,
            events_folded=folded,
            validation_passes=validation_passes,
            progress_seq=progress_seq,
        )
        if release_requested and folded == 96 and validation_passes >= 1:
            conn.execute(
                "UPDATE ingestion_watermark SET last_event_id=?, generation=? WHERE stream='inference'",
                (96, args.batch_id),
            )
            conn.commit()
            write_status(
                phase="committed",
                transaction="released",
                journal_mode=mode,
                events_folded=folded,
                validation_passes=validation_passes,
                progress_seq=progress_seq,
            )
            break
        time.sleep(0.04)
except BaseException as exc:
    try:
        conn.rollback()
    except Exception:
        pass
    write_status(
        phase="failed",
        transaction="rolled_back",
        journal_mode=mode,
        events_folded=folded,
        validation_passes=validation_passes,
        progress_seq=folded + validation_passes,
        error=type(exc).__name__,
    )
    raise
finally:
    conn.close()
