#!/usr/bin/env python3
import os
import sqlite3
import sys

db = sys.argv[1]
for suffix in ("", "-wal", "-shm"):
    try:
        os.unlink(db + suffix)
    except FileNotFoundError:
        pass
os.makedirs(os.path.dirname(db), exist_ok=True)
conn = sqlite3.connect(db, timeout=2)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA synchronous=FULL")
conn.execute("PRAGMA foreign_keys=ON")
conn.executescript(
    """
    CREATE TABLE staged_events (
      event_id INTEGER PRIMARY KEY,
      observed_minute INTEGER NOT NULL,
      model TEXT NOT NULL,
      input_tokens INTEGER NOT NULL,
      output_tokens INTEGER NOT NULL,
      latency_ms INTEGER NOT NULL
    );
    CREATE TABLE hourly_rollups (
      hour_bucket TEXT NOT NULL,
      model TEXT NOT NULL,
      request_count INTEGER NOT NULL,
      input_tokens INTEGER NOT NULL,
      output_tokens INTEGER NOT NULL,
      latency_ms INTEGER NOT NULL,
      PRIMARY KEY(hour_bucket, model)
    );
    CREATE TABLE ingestion_watermark (
      stream TEXT PRIMARY KEY,
      last_event_id INTEGER NOT NULL,
      generation TEXT NOT NULL
    );
    CREATE TABLE retry_decisions (
      decision_id INTEGER PRIMARY KEY AUTOINCREMENT,
      job_key TEXT NOT NULL UNIQUE,
      decision TEXT NOT NULL,
      reason TEXT NOT NULL,
      requested_by TEXT NOT NULL
    );
    CREATE TABLE retry_audit (
      audit_id INTEGER PRIMARY KEY AUTOINCREMENT,
      decision_id INTEGER NOT NULL,
      action TEXT NOT NULL,
      incident TEXT NOT NULL UNIQUE,
      FOREIGN KEY(decision_id) REFERENCES retry_decisions(decision_id)
    );
    """
)
models = ("qwen35-eval", "vision-reranker", "safety-judge")
rows = []
for event_id in range(1, 97):
    rows.append((
        event_id,
        (event_id - 1) % 60,
        models[(event_id - 1) % len(models)],
        80 + (event_id * 13) % 240,
        20 + (event_id * 7) % 100,
        110 + (event_id * 17) % 480,
    ))
conn.executemany("INSERT INTO staged_events VALUES (?,?,?,?,?,?)", rows)
conn.execute(
    "INSERT INTO ingestion_watermark(stream,last_event_id,generation) VALUES (?,?,?)",
    ("inference", 0, "rollup-previous"),
)
conn.commit()
assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
conn.close()
