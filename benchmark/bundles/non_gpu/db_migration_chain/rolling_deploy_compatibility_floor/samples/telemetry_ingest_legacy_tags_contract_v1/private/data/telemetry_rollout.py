#!/usr/bin/env python3
"""Small telemetry schema-rollout control plane backed by a real SQLite DB."""

import argparse
import datetime as dt
import json
import os
import pathlib
import signal
import sqlite3
import sys
import time
import uuid

OLD_VERSION = 2026080102
TARGET_VERSION = 2026080403
HEARTBEAT_TTL = 2.5


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def connect(path):
    db = sqlite3.connect(path, timeout=8.0)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA busy_timeout=8000")
    return db


def proc_start(pid):
    try:
        return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    except (OSError, IndexError):
        return "missing"


def process_matches(pid, start):
    return pid > 1 and start != "missing" and proc_start(pid) == str(start)


def columns(db, table):
    return [row[1] for row in db.execute(f"PRAGMA table_info({table})")]


def initialize(path):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    db = connect(path)
    db.executescript(
        """
        CREATE TABLE schema_versions(
          version INTEGER PRIMARY KEY,
          description TEXT NOT NULL,
          applied_at TEXT NOT NULL
        );
        CREATE TABLE schema_consumers(
          consumer_id TEXT PRIMARY KEY,
          service TEXT NOT NULL,
          release TEXT NOT NULL,
          floor_version INTEGER NOT NULL,
          state TEXT NOT NULL,
          pid INTEGER NOT NULL,
          process_start TEXT NOT NULL,
          registration_nonce TEXT NOT NULL,
          heartbeat_epoch REAL NOT NULL,
          operations INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE telemetry_events(
          event_id INTEGER PRIMARY KEY AUTOINCREMENT,
          received_at TEXT NOT NULL,
          source TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          legacy_tags_json TEXT NOT NULL
        );
        CREATE TABLE event_tags(
          event_id INTEGER NOT NULL,
          tag_key TEXT NOT NULL,
          tag_value TEXT NOT NULL,
          PRIMARY KEY(event_id, tag_key)
        );
        """
    )
    db.execute(
        "INSERT INTO schema_versions VALUES(?,?,?)",
        (OLD_VERSION, "expand normalized event tags", utc_now()),
    )
    for idx in range(1, 13):
        tags = {"env": "prod", "shard": str(idx % 3), "sdk": "python"}
        cursor = db.execute(
            "INSERT INTO telemetry_events(received_at,source,payload_json,legacy_tags_json) VALUES(?,?,?,?)",
            (utc_now(), f"gateway-{idx % 4}", json.dumps({"seq": idx}), json.dumps(tags, sort_keys=True)),
        )
        for key, value in tags.items():
            db.execute("INSERT INTO event_tags VALUES(?,?,?)", (cursor.lastrowid, key, value))
    db.commit()
    db.close()
    print(json.dumps({"initialized": path, "version": OLD_VERSION, "events": 12}, sort_keys=True))


def consumer_status(db, consumer_id):
    row = db.execute("SELECT * FROM schema_consumers WHERE consumer_id=?", (consumer_id,)).fetchone()
    if not row:
        return None
    result = dict(row)
    result["process_matches"] = process_matches(int(row["pid"]), row["process_start"])
    result["heartbeat_age"] = max(0.0, time.time() - float(row["heartbeat_epoch"]))
    result["live"] = (
        row["state"] == "active"
        and result["process_matches"]
        and result["heartbeat_age"] <= HEARTBEAT_TTL
    )
    return result


def old_replica(args):
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    pid = os.getpid()
    start = proc_start(pid)
    nonce = str(uuid.uuid4())
    pathlib.Path(args.pid_file).write_text(f"{pid}\n")
    db = connect(args.database)
    db.execute(
        """INSERT OR REPLACE INTO schema_consumers
        (consumer_id,service,release,floor_version,state,pid,process_start,registration_nonce,heartbeat_epoch,operations)
        VALUES(?,?,?,?,?,?,?,?,?,0)""",
        (args.consumer_id, args.service, args.release, OLD_VERSION, "active", pid, start, nonce, time.time()),
    )
    db.commit()
    sequence = 1000
    try:
        while not stopping:
            sequence += 1
            tags = {"env": "prod", "route": f"ingest-{sequence % 5}", "compat": "v7"}
            try:
                db.execute("BEGIN IMMEDIATE")
                cursor = db.execute(
                    "INSERT INTO telemetry_events(received_at,source,payload_json,legacy_tags_json) VALUES(?,?,?,?)",
                    (utc_now(), args.consumer_id, json.dumps({"seq": sequence}), json.dumps(tags, sort_keys=True)),
                )
                for key, value in tags.items():
                    db.execute("INSERT INTO event_tags VALUES(?,?,?)", (cursor.lastrowid, key, value))
                legacy = db.execute(
                    "SELECT legacy_tags_json FROM telemetry_events WHERE event_id=?", (cursor.lastrowid,)
                ).fetchone()[0]
                if json.loads(legacy).get("compat") != "v7":
                    raise RuntimeError("legacy tag round-trip failed")
                db.execute(
                    "UPDATE schema_consumers SET heartbeat_epoch=?, operations=operations+1 WHERE consumer_id=? AND registration_nonce=?",
                    (time.time(), args.consumer_id, nonce),
                )
                db.commit()
            except Exception:
                db.rollback()
                raise
            time.sleep(0.18)
    finally:
        try:
            db.execute(
                "UPDATE schema_consumers SET state='retired', heartbeat_epoch=? WHERE consumer_id=? AND registration_nonce=?",
                (time.time(), args.consumer_id, nonce),
            )
            db.commit()
        except sqlite3.Error:
            pass
        db.close()


def status(args):
    db = connect(args.database)
    consumer = consumer_status(db, args.consumer_id)
    version = db.execute("SELECT max(version) FROM schema_versions").fetchone()[0]
    cols = columns(db, "telemetry_events")
    events = db.execute("SELECT count(*) FROM telemetry_events").fetchone()[0]
    tags = db.execute("SELECT count(*) FROM event_tags").fetchone()[0]
    db.close()
    result = {"version": version, "columns": cols, "events": events, "tag_rows": tags, "consumer": consumer}
    print(json.dumps(result, sort_keys=True))
    return 0 if consumer and consumer["live"] else 1


def live_blockers(db, target):
    blockers = []
    for row in db.execute("SELECT * FROM schema_consumers WHERE floor_version < ?", (target,)):
        current = consumer_status(db, row["consumer_id"])
        if current and current["live"]:
            blockers.append(current)
    return blockers


def migrate(args):
    db = connect(args.database)
    if args.target != TARGET_VERSION:
        print(f"unsupported target {args.target}", file=sys.stderr)
        return 2
    blockers = live_blockers(db, args.target)
    if blockers:
        ids = ",".join(row["consumer_id"] for row in blockers)
        print(f"COMPATIBILITY_GATE_BLOCKED target={args.target} live_consumers={ids}", file=sys.stderr)
        return 42
    if "legacy_tags_json" not in columns(db, "telemetry_events"):
        print("contract already applied", file=sys.stderr)
        return 3
    db.execute("BEGIN IMMEDIATE")
    db.executescript(
        """
        CREATE TABLE telemetry_events_contract(
          event_id INTEGER PRIMARY KEY AUTOINCREMENT,
          received_at TEXT NOT NULL,
          source TEXT NOT NULL,
          payload_json TEXT NOT NULL
        );
        INSERT INTO telemetry_events_contract(event_id,received_at,source,payload_json)
          SELECT event_id,received_at,source,payload_json FROM telemetry_events;
        DROP TABLE telemetry_events;
        ALTER TABLE telemetry_events_contract RENAME TO telemetry_events;
        """
    )
    db.execute(
        "INSERT INTO schema_versions VALUES(?,?,?)",
        (TARGET_VERSION, "contract normalized event tags", utc_now()),
    )
    db.commit()
    version = db.execute("SELECT max(version) FROM schema_versions").fetchone()[0]
    event_count = db.execute("SELECT count(*) FROM telemetry_events").fetchone()[0]
    tag_count = db.execute("SELECT count(*) FROM event_tags").fetchone()[0]
    db.close()
    report = {
        "status": "applied",
        "target": version,
        "legacy_column_removed": True,
        "event_count": event_count,
        "normalized_tag_rows": tag_count,
    }
    pathlib.Path(args.report).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"MIGRATION_APPLIED target={version} legacy_tags_json=removed event_tags={tag_count}")
    return 0


def smoke(args):
    db = connect(args.database)
    version = db.execute("SELECT max(version) FROM schema_versions").fetchone()[0]
    cols = columns(db, "telemetry_events")
    joined = db.execute(
        "SELECT count(DISTINCT e.event_id) FROM telemetry_events e JOIN event_tags t ON t.event_id=e.event_id"
    ).fetchone()[0]
    total = db.execute("SELECT count(*) FROM telemetry_events").fetchone()[0]
    ok = version == TARGET_VERSION and "legacy_tags_json" not in cols and joined == total and total > 0
    payload = {"ok": ok, "version": version, "columns": cols, "events_with_tags": joined, "events": total}
    pathlib.Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    db.close()
    print("TAG_CONTRACT_OK=1" if ok else "TAG_CONTRACT_OK=0")
    return 0 if ok else 1


def retire(args):
    db = connect(args.database)
    current = consumer_status(db, args.consumer_id)
    if not current:
        print("consumer not registered", file=sys.stderr)
        return 4
    if current["live"]:
        print(f"RETIRE_REFUSED_LIVE_CONSUMER consumer={args.consumer_id} pid={current['pid']}", file=sys.stderr)
        return 43
    db.execute("UPDATE schema_consumers SET state='retired' WHERE consumer_id=?", (args.consumer_id,))
    db.commit()
    db.close()
    print(f"CONSUMER_RETIRED consumer={args.consumer_id}")
    return 0


def parser():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    p = sub.add_parser("init")
    p.add_argument("--database", required=True)
    p.set_defaults(func=lambda a: (initialize(a.database) or 0))
    p = sub.add_parser("old-replica")
    p.add_argument("--database", required=True)
    p.add_argument("--pid-file", required=True)
    p.add_argument("--consumer-id", required=True)
    p.add_argument("--service", required=True)
    p.add_argument("--release", required=True)
    p.set_defaults(func=old_replica)
    p = sub.add_parser("status")
    p.add_argument("--database", required=True)
    p.add_argument("--consumer-id", required=True)
    p.set_defaults(func=status)
    p = sub.add_parser("finalize-tags")
    p.add_argument("--database", required=True)
    p.add_argument("--target", type=int, required=True)
    p.add_argument("--report", required=True)
    p.set_defaults(func=migrate)
    p = sub.add_parser("verify-tags")
    p.add_argument("--database", required=True)
    p.add_argument("--output", required=True)
    p.set_defaults(func=smoke)
    p = sub.add_parser("retire-consumer")
    p.add_argument("--database", required=True)
    p.add_argument("--consumer-id", required=True)
    p.set_defaults(func=retire)
    return ap


if __name__ == "__main__":
    command_parser = parser()
    command_args = command_parser.parse_args()
    raise SystemExit(command_args.func(command_args))
