#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import json
import pathlib
import sqlite3
import sys


def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def connect(path):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), timeout=3.0)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=3000")
    con.execute("PRAGMA journal_mode=WAL")
    return con


def create_schema(con):
    con.executescript(
        """
        CREATE TABLE IF NOT EXISTS routes(
          route_key TEXT PRIMARY KEY,
          target_model TEXT NOT NULL,
          revision TEXT NOT NULL,
          runtime TEXT NOT NULL,
          config_json TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS route_events(
          event_id INTEGER PRIMARY KEY AUTOINCREMENT,
          route_key TEXT NOT NULL,
          operation TEXT NOT NULL,
          old_target TEXT,
          old_revision TEXT,
          old_runtime TEXT,
          new_target TEXT,
          new_revision TEXT,
          new_runtime TEXT,
          actor TEXT NOT NULL,
          event_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS inference_checks(
          check_id INTEGER PRIMARY KEY AUTOINCREMENT,
          route_key TEXT NOT NULL,
          resolved_target TEXT NOT NULL,
          request_count INTEGER NOT NULL,
          config_digest TEXT NOT NULL,
          resolver_pid INTEGER NOT NULL,
          checked_at TEXT NOT NULL
        );
        CREATE TRIGGER IF NOT EXISTS routes_audit_insert
        AFTER INSERT ON routes BEGIN
          INSERT INTO route_events(route_key,operation,old_target,old_revision,old_runtime,new_target,new_revision,new_runtime,actor,event_at)
          VALUES(NEW.route_key,'INSERT',NULL,NULL,NULL,NEW.target_model,NEW.revision,NEW.runtime,'sqlite.insert',NEW.updated_at);
        END;
        CREATE TRIGGER IF NOT EXISTS routes_audit_update
        AFTER UPDATE ON routes BEGIN
          INSERT INTO route_events(route_key,operation,old_target,old_revision,old_runtime,new_target,new_revision,new_runtime,actor,event_at)
          VALUES(NEW.route_key,'UPDATE',OLD.target_model,OLD.revision,OLD.runtime,NEW.target_model,NEW.revision,NEW.runtime,'sqlite.update',NEW.updated_at);
        END;
        CREATE TRIGGER IF NOT EXISTS routes_audit_delete
        AFTER DELETE ON routes BEGIN
          INSERT INTO route_events(route_key,operation,old_target,old_revision,old_runtime,new_target,new_revision,new_runtime,actor,event_at)
          VALUES(OLD.route_key,'DELETE',OLD.target_model,OLD.revision,OLD.runtime,NULL,NULL,NULL,'sqlite.delete',strftime('%Y-%m-%dT%H:%M:%SZ','now'));
        END;
        """
    )


def route_payload(args, config):
    return {
        "route_key": args.key,
        "target_model": args.target,
        "revision": args.revision,
        "runtime": args.runtime,
        "config": config,
    }


def row_payload(row, path):
    if row is None:
        return None
    out = dict(row)
    out["config"] = json.loads(out.pop("config_json"))
    out["database_path"] = str(path)
    return out


def cmd_init(args):
    path = pathlib.Path(args.db)
    if args.reset:
        for suffix in ("", "-wal", "-shm"):
            path.with_name(path.name + suffix).unlink(missing_ok=True)
    con = connect(path)
    create_schema(con)
    if args.seed_incumbent:
        config = {
            "request_batch": args.request_file,
            "health_fixture": args.health_file,
            "owner": "inference-routing",
        }
        stamp = now()
        con.execute(
            "INSERT INTO routes VALUES (?,?,?,?,?,?,?)",
            (
                "embedding.production.default",
                "embedder-prod-v1",
                "2026.07.18",
                "onnxruntime",
                canonical(config),
                stamp,
                stamp,
            ),
        )
    con.commit()
    print(json.dumps({"ok": True, "database_path": str(path), "seeded_incumbent": bool(args.seed_incumbent)}, indent=2, sort_keys=True))


def cmd_assign(args):
    path = pathlib.Path(args.db)
    con = connect(path)
    row = con.execute("SELECT * FROM routes WHERE route_key=?", (args.key,)).fetchone()
    if row is None:
        print("ERROR: exact route key is not registered", file=sys.stderr)
        raise SystemExit(20)
    old = dict(row)
    config = {
        "request_batch": "/var/lib/inference_catalog/requests/embed_batch.json",
        "health_fixture": "/var/lib/inference_catalog/models/embedder-prod-v1-health.json",
        "owner": "inference-routing",
        "last_assignment": args.target,
    }
    stamp = now()
    con.execute(
        "UPDATE routes SET target_model=?, revision=?, runtime=?, config_json=?, updated_at=? WHERE route_key=?",
        (args.target, args.revision, args.runtime, canonical(config), stamp, args.key),
    )
    event = con.execute("SELECT max(event_id) FROM route_events WHERE route_key=?", (args.key,)).fetchone()[0]
    if event is not None:
        con.execute("UPDATE route_events SET actor=? WHERE event_id=?", ("catalogctl.route.assign", event))
    con.commit()
    resolved = con.execute("SELECT * FROM routes WHERE route_key=?", (args.key,)).fetchone()
    print(json.dumps({"ok": True, "action": "route_assign", "database_path": str(path), "previous": old, "resolved": row_payload(resolved, path)}, indent=2, sort_keys=True))


def cmd_resolve(args):
    path = pathlib.Path(args.db)
    con = connect(path)
    row = con.execute("SELECT * FROM routes WHERE route_key=?", (args.key,)).fetchone()
    if row is None:
        print("ERROR: route key not found", file=sys.stderr)
        raise SystemExit(21)
    out = row_payload(row, path)
    if args.expect_target and out["target_model"] != args.expect_target:
        print(json.dumps({"ok": False, "expected_target": args.expect_target, "resolved": out}, indent=2, sort_keys=True))
        raise SystemExit(22)
    out["ok"] = True
    print(json.dumps(out, indent=2, sort_keys=True))


def cmd_snapshot(args):
    path = pathlib.Path(args.db)
    con = connect(path)
    create_schema(con)
    rows = con.execute("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
    schema_text = "\n".join("|".join("" if v is None else str(v) for v in row) for row in rows)
    routes = [row_payload(row, path) for row in con.execute("SELECT * FROM routes ORDER BY route_key")]
    events = [dict(row) for row in con.execute("SELECT * FROM route_events ORDER BY event_id")]
    checks = [dict(row) for row in con.execute("SELECT * FROM inference_checks ORDER BY check_id")]
    print(json.dumps({"ok": True, "database_path": str(path), "schema_digest": hashlib.sha256(schema_text.encode()).hexdigest(), "routes": routes, "route_events": events, "inference_checks": checks}, indent=2, sort_keys=True))


def parser():
    p = argparse.ArgumentParser(prog="catalogctl")
    sub = p.add_subparsers(dest="area", required=True)
    schema = sub.add_parser("schema")
    ss = schema.add_subparsers(dest="command", required=True)
    init = ss.add_parser("init")
    init.add_argument("--db", required=True)
    init.add_argument("--reset", action="store_true")
    init.add_argument("--seed-incumbent", action="store_true")
    init.add_argument("--request-file", default="")
    init.add_argument("--health-file", default="")
    init.set_defaults(func=cmd_init)
    route = sub.add_parser("route")
    rs = route.add_subparsers(dest="command", required=True)
    assign = rs.add_parser("assign")
    assign.add_argument("--db", required=True)
    assign.add_argument("--key", required=True)
    assign.add_argument("--target", required=True)
    assign.add_argument("--revision", required=True)
    assign.add_argument("--runtime", required=True)
    assign.set_defaults(func=cmd_assign)
    resolve = rs.add_parser("resolve")
    resolve.add_argument("--db", required=True)
    resolve.add_argument("--key", required=True)
    resolve.add_argument("--expect-target", default="")
    resolve.set_defaults(func=cmd_resolve)
    catalog = sub.add_parser("catalog")
    cs = catalog.add_subparsers(dest="command", required=True)
    snap = cs.add_parser("snapshot")
    snap.add_argument("--db", required=True)
    snap.set_defaults(func=cmd_snapshot)
    return p


if __name__ == "__main__":
    parsed = parser().parse_args()
    parsed.func(parsed)
