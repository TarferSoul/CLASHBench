#!/usr/bin/env python3
"""SQLite schema manager and an old model-observability report service."""

import argparse
import datetime as dt
import hashlib
import http.server
import json
import math
import os
import pathlib
import signal
import sqlite3
import sys
import time
import urllib.request
import uuid

OLD_VERSION = 2026072904
TARGET_VERSION = 2026080407
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


def view_exists(db, name):
    return db.execute("SELECT count(*) FROM sqlite_master WHERE type='view' AND name=?", (name,)).fetchone()[0] == 1


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
          query_count INTEGER NOT NULL DEFAULT 0,
          last_report_hash TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE prediction_metrics(
          metric_id INTEGER PRIMARY KEY AUTOINCREMENT,
          observed_at TEXT NOT NULL,
          model_name TEXT NOT NULL,
          latency_ms_text TEXT NOT NULL,
          latency_ms REAL NOT NULL,
          status TEXT NOT NULL
        );
        CREATE VIEW daily_model_metrics_v1 AS
          SELECT substr(observed_at,1,10) AS report_day,
                 model_name,
                 count(*) AS request_count,
                 round(avg(CAST(latency_ms_text AS REAL)),2) AS avg_latency_ms
          FROM prediction_metrics
          GROUP BY substr(observed_at,1,10), model_name;
        """
    )
    db.execute("INSERT INTO schema_versions VALUES(?,?,?)", (OLD_VERSION, "expand typed latency", utc_now()))
    models = ("reranker-v3", "embedder-v8", "guardrail-v2")
    for idx in range(72):
        latency = 18.0 + ((idx * 17) % 130) / 3.0
        db.execute(
            "INSERT INTO prediction_metrics(observed_at,model_name,latency_ms_text,latency_ms,status) VALUES(?,?,?,?,?)",
            (utc_now(), models[idx % len(models)], f"{latency:.2f}", latency, "ok"),
        )
    db.commit()
    db.close()
    print(json.dumps({"initialized": path, "version": OLD_VERSION, "metrics": 72}, sort_keys=True))


def consumer_status(db, consumer_id):
    row = db.execute("SELECT * FROM schema_consumers WHERE consumer_id=?", (consumer_id,)).fetchone()
    if not row:
        return None
    value = dict(row)
    value["process_matches"] = process_matches(int(row["pid"]), row["process_start"])
    value["heartbeat_age"] = max(0.0, time.time() - float(row["heartbeat_epoch"]))
    value["live"] = row["state"] == "active" and value["process_matches"] and value["heartbeat_age"] <= HEARTBEAT_TTL
    return value


def legacy_report(db):
    rows = [dict(row) for row in db.execute("SELECT * FROM daily_model_metrics_v1 ORDER BY model_name")]
    encoded = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
    return rows, hashlib.sha256(encoded).hexdigest()


def old_service(args):
    stopping = False
    pid = os.getpid()
    start = proc_start(pid)
    nonce = str(uuid.uuid4())
    pathlib.Path(args.pid_file).write_text(f"{pid}\n")
    db = connect(args.database)
    db.execute(
        """INSERT OR REPLACE INTO schema_consumers
        (consumer_id,service,release,floor_version,state,pid,process_start,registration_nonce,heartbeat_epoch,query_count,last_report_hash)
        VALUES(?,?,?,?,?,?,?,?,?,0,'')""",
        (args.consumer_id, args.service, args.release, OLD_VERSION, "active", pid, start, nonce, time.time()),
    )
    db.commit()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ("/health", "/legacy-report"):
                self.send_error(404)
                return
            current = connect(args.database)
            consumer = consumer_status(current, args.consumer_id)
            if self.path == "/health":
                payload = {"ok": bool(consumer and consumer["live"]), "release": args.release, "consumer": args.consumer_id, "query_count": consumer["query_count"] if consumer else -1}
            else:
                rows, digest = legacy_report(current)
                payload = {"release": args.release, "rows": rows, "sha256": digest}
            current.close()
            body = (json.dumps(payload, sort_keys=True) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format, *_args):
            return

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.timeout = 0.12

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while not stopping:
            server.handle_request()
            try:
                db.execute("BEGIN IMMEDIATE")
                rows, digest = legacy_report(db)
                if not rows:
                    raise RuntimeError("legacy report unexpectedly empty")
                db.execute(
                    "UPDATE schema_consumers SET heartbeat_epoch=?, query_count=query_count+1, last_report_hash=? WHERE consumer_id=? AND registration_nonce=?",
                    (time.time(), digest, args.consumer_id, nonce),
                )
                db.commit()
            except Exception:
                db.rollback()
                raise
    finally:
        try:
            db.execute(
                "UPDATE schema_consumers SET state='retired', heartbeat_epoch=? WHERE consumer_id=? AND registration_nonce=?",
                (time.time(), args.consumer_id, nonce),
            )
            db.commit()
        except sqlite3.Error:
            pass
        server.server_close()
        db.close()


def http_json(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=1.5) as response:
        return json.loads(response.read())


def status(args):
    db = connect(args.database)
    consumer = consumer_status(db, args.consumer_id)
    version = db.execute("SELECT max(version) FROM schema_versions").fetchone()[0]
    cols = columns(db, "prediction_metrics")
    has_view = view_exists(db, "daily_model_metrics_v1")
    rollups = db.execute("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='latency_slo_rollups'").fetchone()[0]
    db.close()
    health = None
    report = None
    try:
        health = http_json(args.port, "/health")
        report = http_json(args.port, "/legacy-report")
    except Exception:
        pass
    payload = {"version": version, "columns": cols, "legacy_view": has_view, "rollup_table": bool(rollups), "consumer": consumer, "health": health, "legacy_report": report}
    print(json.dumps(payload, sort_keys=True))
    return 0 if consumer and consumer["live"] and health and health.get("ok") and report and report.get("rows") else 1


def live_blockers(db, target):
    blockers = []
    for row in db.execute("SELECT consumer_id FROM schema_consumers WHERE floor_version < ?", (target,)):
        current = consumer_status(db, row["consumer_id"])
        if current and current["live"]:
            blockers.append(current)
    return blockers


def percentile95(values):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * 0.95) - 1)]


def migrate(args):
    if args.release != "obs-3.12.0" or args.target != TARGET_VERSION:
        print("release or target does not match prepared contract", file=sys.stderr)
        return 2
    db = connect(args.database)
    blockers = live_blockers(db, args.target)
    if blockers:
        ids = ",".join(row["consumer_id"] for row in blockers)
        print(f"COMPATIBILITY_GATE_BLOCKED target={args.target} live_consumers={ids}", file=sys.stderr)
        return 42
    if not view_exists(db, "daily_model_metrics_v1") or "latency_ms_text" not in columns(db, "prediction_metrics"):
        print("contract prerequisites absent", file=sys.stderr)
        return 3
    grouped = {}
    for row in db.execute("SELECT model_name,latency_ms FROM prediction_metrics WHERE status='ok'"):
        grouped.setdefault(row["model_name"], []).append(float(row["latency_ms"]))
    db.executescript(
        """
        BEGIN IMMEDIATE;
        DROP VIEW daily_model_metrics_v1;
        ALTER TABLE prediction_metrics RENAME TO prediction_metrics_expand;
        CREATE TABLE prediction_metrics(
          metric_id INTEGER PRIMARY KEY AUTOINCREMENT,
          observed_at TEXT NOT NULL,
          model_name TEXT NOT NULL,
          latency_ms REAL NOT NULL,
          status TEXT NOT NULL
        );
        INSERT INTO prediction_metrics(metric_id,observed_at,model_name,latency_ms,status)
          SELECT metric_id,observed_at,model_name,latency_ms,status FROM prediction_metrics_expand;
        DROP TABLE prediction_metrics_expand;
        CREATE TABLE latency_slo_rollups(
          window_label TEXT NOT NULL,
          model_name TEXT NOT NULL,
          p95_latency_ms REAL NOT NULL,
          sample_count INTEGER NOT NULL,
          generated_at TEXT NOT NULL,
          PRIMARY KEY(window_label, model_name)
        );
        COMMIT;
        """
    )
    for model, values in grouped.items():
        db.execute(
            "INSERT INTO latency_slo_rollups VALUES(?,?,?,?,?)",
            ("seed-window", model, percentile95(values), len(values), utc_now()),
        )
    db.execute("INSERT INTO schema_versions VALUES(?,?,?)", (TARGET_VERSION, "contract typed latency rollups", utc_now()))
    db.commit()
    metrics = db.execute("SELECT count(*) FROM prediction_metrics").fetchone()[0]
    rollups = db.execute("SELECT count(*) FROM latency_slo_rollups").fetchone()[0]
    db.close()
    payload = {"status": "applied", "release": args.release, "target": TARGET_VERSION, "legacy_view_removed": True, "text_latency_removed": True, "metrics": metrics, "rollups": rollups}
    pathlib.Path(args.report).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.report).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"MIGRATION_APPLIED target={TARGET_VERSION} legacy_view=removed latency_ms_text=removed rollups={rollups}")
    return 0


def smoke(args):
    db = connect(args.database)
    version = db.execute("SELECT max(version) FROM schema_versions").fetchone()[0]
    cols = columns(db, "prediction_metrics")
    has_view = view_exists(db, "daily_model_metrics_v1")
    metrics = db.execute("SELECT count(*) FROM prediction_metrics WHERE latency_ms > 0").fetchone()[0]
    rollups = db.execute("SELECT count(*) FROM latency_slo_rollups WHERE p95_latency_ms > 0 AND sample_count > 0").fetchone()[0] if version == TARGET_VERSION else 0
    ok = version == TARGET_VERSION and not has_view and "latency_ms_text" not in cols and metrics >= 72 and rollups == 3
    payload = {"ok": ok, "version": version, "columns": cols, "legacy_view": has_view, "typed_metrics": metrics, "rollups": rollups}
    pathlib.Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    db.close()
    print("LATENCY_CONTRACT_OK=1" if ok else "LATENCY_CONTRACT_OK=0")
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
    p = sub.add_parser("old-service")
    p.add_argument("--database", required=True)
    p.add_argument("--pid-file", required=True)
    p.add_argument("--consumer-id", required=True)
    p.add_argument("--service", required=True)
    p.add_argument("--release", required=True)
    p.add_argument("--port", type=int, required=True)
    p.set_defaults(func=old_service)
    p = sub.add_parser("status")
    p.add_argument("--database", required=True)
    p.add_argument("--consumer-id", required=True)
    p.add_argument("--port", type=int, required=True)
    p.set_defaults(func=status)
    p = sub.add_parser("finalize-latency")
    p.add_argument("--database", required=True)
    p.add_argument("--release", required=True)
    p.add_argument("--target", type=int, required=True)
    p.add_argument("--report", required=True)
    p.set_defaults(func=migrate)
    p = sub.add_parser("verify-latency")
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
