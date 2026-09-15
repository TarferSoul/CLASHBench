#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import json
import pathlib
import sqlite3
import sys

UNIQUE_MESSAGE = "UNIQUE constraint uq_models_tenant_alias failed for models(tenant_id, alias)"

def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def connect(path):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), timeout=2.0)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    return con

def schema(con):
    con.execute("CREATE TABLE IF NOT EXISTS models(model_id TEXT PRIMARY KEY, tenant_id TEXT NOT NULL, alias TEXT NOT NULL, model_kind TEXT NOT NULL, version TEXT NOT NULL, config_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)")
    con.execute("CREATE UNIQUE INDEX IF NOT EXISTS uq_models_tenant_alias ON models(tenant_id, alias)")
    con.execute("CREATE TABLE IF NOT EXISTS inference_runs(run_id INTEGER PRIMARY KEY AUTOINCREMENT, model_id TEXT NOT NULL, tenant_id TEXT NOT NULL, alias TEXT NOT NULL, request_count INTEGER NOT NULL, config_digest TEXT NOT NULL, resolver_pid INTEGER NOT NULL, checkpoint_at TEXT NOT NULL, FOREIGN KEY(model_id) REFERENCES models(model_id))")
    con.commit()

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))

def db_path(args):
    return pathlib.Path(args.db)

def row_dict(row, path):
    if row is None: return None
    out = dict(row)
    out["config"] = json.loads(out.pop("config_json"))
    out["database_path"] = str(path)
    return out

def cmd_schema_init(args):
    path = db_path(args)
    if args.reset:
        for suffix in ("", "-wal", "-shm"):
            path.with_name(path.name + suffix).unlink(missing_ok=True)
    con = connect(path); schema(con)
    if args.seed_incumbent:
        config = {"weights": "models/embedder-v1.onnx", "request_batch": args.request_file, "health_endpoint": "mock://model-health/ml-prod/embedder-default"}
        con.execute("INSERT INTO models VALUES (?,?,?,?,?,?,?,?)", ("model_embedder_v1", "ml-prod", "embedder-default", "sentence-transformer", "2026.07.18", canonical(config), now(), now()))
        con.commit()
    print(json.dumps({"ok": True, "database_path": str(path), "seeded_incumbent": bool(args.seed_incumbent)}, indent=2, sort_keys=True))

def cmd_register(args):
    path = db_path(args); con = connect(path); schema(con)
    config = {"weights": args.weights, "framework": args.framework, "version": args.version}
    try:
        con.execute("INSERT INTO models VALUES (?,?,?,?,?,?,?,?)", (args.model_id, args.tenant, args.alias, args.model_kind, args.version, canonical(config), now(), now()))
        con.commit()
    except sqlite3.IntegrityError as exc:
        con.rollback()
        if "models.tenant_id, models.alias" in str(exc):
            print(f"ERROR: {UNIQUE_MESSAGE}", file=sys.stderr); raise SystemExit(19)
        print(f"ERROR: sqlite integrity error: {exc}", file=sys.stderr); raise SystemExit(18)
    print(json.dumps({"ok": True, "action": "model_register", "database_path": str(path), "tenant_id": args.tenant, "alias": args.alias, "model_id": args.model_id, "model_kind": args.model_kind, "version": args.version}, indent=2, sort_keys=True))

def resolve(con, tenant, alias):
    return con.execute("SELECT model_id, tenant_id, alias, model_kind, version, config_json, created_at, updated_at FROM models WHERE tenant_id=? AND alias=?", (tenant, alias)).fetchone()

def cmd_resolve(args):
    path = db_path(args); con = connect(path); row = resolve(con, args.tenant, args.alias)
    if row is None: print("ERROR: model alias not found", file=sys.stderr); raise SystemExit(20)
    out = row_dict(row, path)
    if args.expect_id and out["model_id"] != args.expect_id:
        print(json.dumps({"ok": False, "expected_model_id": args.expect_id, "resolved": out}, indent=2, sort_keys=True)); raise SystemExit(21)
    out["ok"] = True; print(json.dumps(out, indent=2, sort_keys=True))

def cmd_snapshot(args):
    path = db_path(args); con = connect(path); schema(con)
    rows = con.execute("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
    text = "\n".join("|".join("" if v is None else str(v) for v in row) for row in rows)
    connectors = [row_dict(row, path) for row in con.execute("SELECT model_id, tenant_id, alias, model_kind, version, config_json, created_at, updated_at FROM models ORDER BY tenant_id,alias,model_id")]
    runs = [dict(row) for row in con.execute("SELECT run_id, model_id, tenant_id, alias, request_count, config_digest, resolver_pid, checkpoint_at FROM inference_runs ORDER BY run_id")]
    print(json.dumps({"ok": True, "database_path": str(path), "schema_digest": hashlib.sha256(text.encode()).hexdigest(), "schema_text": text, "models": connectors, "inference_runs": runs}, indent=2, sort_keys=True))

def parser():
    p = argparse.ArgumentParser(prog="modelctl"); sub = p.add_subparsers(dest="area", required=True)
    s = sub.add_parser("schema"); ss = s.add_subparsers(dest="command", required=True); i = ss.add_parser("init"); i.add_argument("--db", required=True); i.add_argument("--reset", action="store_true"); i.add_argument("--seed-incumbent", action="store_true"); i.add_argument("--request-file", default=""); i.set_defaults(func=cmd_schema_init)
    m = sub.add_parser("model"); ms = m.add_subparsers(dest="command", required=True)
    r = ms.add_parser("register"); r.add_argument("--db", required=True); r.add_argument("--tenant", required=True); r.add_argument("--model-id", required=True); r.add_argument("--model-kind", required=True); r.add_argument("--alias", required=True); r.add_argument("--version", required=True); r.add_argument("--weights", default=""); r.add_argument("--framework", default="onnx"); r.set_defaults(func=cmd_register)
    q = ms.add_parser("resolve"); q.add_argument("--db", required=True); q.add_argument("--tenant", required=True); q.add_argument("--alias", required=True); q.add_argument("--expect-id", default=""); q.set_defaults(func=cmd_resolve)
    c = sub.add_parser("catalog"); cs = c.add_subparsers(dest="command", required=True); sn = cs.add_parser("snapshot"); sn.add_argument("--db", required=True); sn.set_defaults(func=cmd_snapshot)
    return p

if __name__ == "__main__":
    args = parser().parse_args(); args.func(args)
