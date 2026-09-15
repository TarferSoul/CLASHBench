#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import sqlite3
import time


DB = pathlib.Path(os.environ["CATALOG_DB"])
JOB_ID = os.environ["A_JOB_ID"]
CONNECTOR_ID = os.environ["A_CONNECTOR_ID"]
CONNECTOR_TYPE = os.environ["A_CONNECTOR_TYPE"]
SOURCE_EVENTS = pathlib.Path(os.environ["SOURCE_EVENTS_FILE"])
HEARTBEAT = pathlib.Path(os.environ["A_HEARTBEAT_FILE"])
LOG_FILE = pathlib.Path(os.environ["A_LOG_FILE"])
RUN_DIR = pathlib.Path(os.environ["A_RUN_DIR"])
STOP_FILE = RUN_DIR / "stop"


def digest_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def file_digest(path):
    target = pathlib.Path(path)
    if not target.exists():
        return ""
    digest = hashlib.sha256()
    with target.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def append_log(message):
    with LOG_FILE.open("a", encoding="utf-8") as handle:
        handle.write(f"{time.time():.3f} {message}\n")


def connect():
    con = sqlite3.connect(str(DB), timeout=1.0)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys=ON")
    con.execute("PRAGMA busy_timeout=1000")
    return con


def load_events():
    events = []
    with SOURCE_EVENTS.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                events.append(json.loads(line))
    return events


def write_heartbeat(payload):
    HEARTBEAT.parent.mkdir(parents=True, exist_ok=True)
    HEARTBEAT.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")


def main():
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    worker_id = f"export-worker-{os.getpid()}"
    batch = 0
    rows_exported = 0
    events = load_events()
    while not STOP_FILE.exists():
        try:
            con = connect()
            row = con.execute(
                """
                SELECT j.job_id, j.state, j.output_path, c.connector_id,
                       c.connector_type, c.schema_digest, c.immutable_generation
                FROM export_jobs AS j
                JOIN connector_catalog AS c ON c.connector_id = j.connector_id
                WHERE j.job_id = ?
                """,
                (JOB_ID,),
            ).fetchone()
            if row is None:
                raise RuntimeError("active export job is missing")
            if row["connector_id"] != CONNECTOR_ID:
                raise RuntimeError(f"job was repointed to {row['connector_id']}")
            if row["connector_type"] != CONNECTOR_TYPE:
                raise RuntimeError(f"connector type changed to {row['connector_type']}")
            output_path = pathlib.Path(row["output_path"])
            output_path.parent.mkdir(parents=True, exist_ok=True)
            batch_events = [events[(batch + offset) % len(events)] for offset in range(2)]
            with output_path.open("a", encoding="utf-8") as handle:
                for event in batch_events:
                    out = {
                        "job_id": JOB_ID,
                        "batch": batch + 1,
                        "event_id": event["event_id"],
                        "event_name": event["event_name"],
                        "connector_id": CONNECTOR_ID,
                        "connector_type": row["connector_type"],
                        "schema_digest": row["schema_digest"],
                        "worker_id": worker_id,
                    }
                    handle.write(json.dumps(out, sort_keys=True) + "\n")
            rows_exported += len(batch_events)
            artifact_digest = file_digest(output_path)
            con.execute(
                """
                UPDATE export_jobs
                SET state = 'active',
                    checkpoint_batch = ?,
                    rows_exported = ?,
                    claimed_by = ?,
                    last_update = datetime('now')
                WHERE job_id = ? AND connector_id = ?
                """,
                (batch + 1, rows_exported, worker_id, JOB_ID, CONNECTOR_ID),
            )
            con.execute(
                """
                INSERT INTO job_checkpoint(job_id, last_batch, rows_exported, artifact_digest, updated_at)
                VALUES (?, ?, ?, ?, datetime('now'))
                ON CONFLICT(job_id) DO UPDATE SET
                  last_batch = excluded.last_batch,
                  rows_exported = excluded.rows_exported,
                  artifact_digest = excluded.artifact_digest,
                  updated_at = excluded.updated_at
                """,
                (JOB_ID, batch + 1, rows_exported, artifact_digest),
            )
            con.commit()
            batch += 1
            heartbeat = {
                "ok": True,
                "pid": os.getpid(),
                "worker_id": worker_id,
                "job_id": JOB_ID,
                "connector_id": CONNECTOR_ID,
                "connector_type": row["connector_type"],
                "schema_digest": row["schema_digest"],
                "batch": batch,
                "rows_exported": rows_exported,
                "artifact_digest": artifact_digest,
                "updated_at": time.time(),
            }
            write_heartbeat(heartbeat)
            append_log(f"batch={batch} rows_exported={rows_exported} connector={CONNECTOR_ID}")
        except Exception as exc:
            write_heartbeat({"ok": False, "pid": os.getpid(), "error": str(exc), "updated_at": time.time()})
            append_log(f"unhealthy error={exc}")
        time.sleep(0.16)


if __name__ == "__main__":
    main()
