#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import sqlite3
import sys


DEFAULT_DB = "/work/catalogs/integration_registry.sqlite"
FOREIGN_KEY_DIAGNOSTIC = "FOREIGN KEY constraint failed"


def utc_now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def schema_digest(path):
    raw = pathlib.Path(path).read_bytes()
    try:
        value = json.loads(raw.decode("utf-8"))
        payload = canonical_json(value).encode("utf-8")
    except Exception:
        payload = raw
    return hashlib.sha256(payload).hexdigest()


def db_path(args):
    return pathlib.Path(getattr(args, "db", "") or os.environ.get("CATALOG_DB") or DEFAULT_DB)


def connect(path):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), timeout=1.2)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys=ON")
    con.execute("PRAGMA busy_timeout=1200")
    return con


def schema_sql():
    return [
        """
        CREATE TABLE IF NOT EXISTS connector_catalog (
          connector_id TEXT PRIMARY KEY,
          connector_type TEXT NOT NULL,
          schema_digest TEXT NOT NULL,
          config_contract_version INTEGER NOT NULL,
          immutable_generation TEXT NOT NULL,
          schema_path TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS export_jobs (
          job_id TEXT PRIMARY KEY,
          connector_id TEXT NOT NULL REFERENCES connector_catalog(connector_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
          state TEXT NOT NULL,
          checkpoint_batch INTEGER NOT NULL DEFAULT 0,
          rows_exported INTEGER NOT NULL DEFAULT 0,
          output_path TEXT NOT NULL,
          claimed_by TEXT,
          last_update TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS job_checkpoint (
          job_id TEXT PRIMARY KEY REFERENCES export_jobs(job_id) ON DELETE CASCADE,
          last_batch INTEGER NOT NULL,
          rows_exported INTEGER NOT NULL,
          artifact_digest TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
        """,
    ]


def apply_schema(con):
    for stmt in schema_sql():
        con.execute(stmt)
    con.commit()


def remove_sqlite_files(path):
    for suffix in ("", "-wal", "-shm"):
        try:
            pathlib.Path(str(path) + suffix).unlink()
        except FileNotFoundError:
            pass


def row_dict(row):
    return None if row is None else dict(row)


def foreign_key_check_clean(con):
    return [tuple(row) for row in con.execute("PRAGMA foreign_key_check").fetchall()]


def connector_row(con, connector_id):
    return con.execute(
        """
        SELECT connector_id, connector_type, schema_digest, config_contract_version,
               immutable_generation, schema_path, created_at
        FROM connector_catalog
        WHERE connector_id = ?
        """,
        (connector_id,),
    ).fetchone()


def reference_count(con, connector_id):
    return con.execute(
        "SELECT COUNT(*) FROM export_jobs WHERE connector_id = ? AND state IN ('queued', 'active')",
        (connector_id,),
    ).fetchone()[0]


def write_report(path, payload):
    if not path:
        return
    report = pathlib.Path(path)
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    report.chmod(0o666)


def emit(payload):
    print(json.dumps(payload, indent=2, sort_keys=True))


def seed_connector(con, args):
    digest = schema_digest(args.incumbent_schema)
    con.execute(
        """
        INSERT INTO connector_catalog(
          connector_id, connector_type, schema_digest, config_contract_version,
          immutable_generation, schema_path, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            args.connector_id,
            args.connector_type,
            digest,
            1,
            "warehouse-events-v1-20260726T055700Z",
            "builtin://warehouse_events_v1.schema.json",
            utc_now(),
        ),
    )
    if args.seed_job:
        con.execute(
            """
            INSERT INTO export_jobs(
              job_id, connector_id, state, checkpoint_batch, rows_exported,
              output_path, claimed_by, last_update
            ) VALUES (?, ?, 'queued', 0, 0, ?, '', ?)
            """,
            (args.job_id, args.connector_id, args.job_output, utc_now()),
        )
        con.execute(
            """
            INSERT INTO job_checkpoint(job_id, last_batch, rows_exported, artifact_digest, updated_at)
            VALUES (?, 0, 0, '', ?)
            """,
            (args.job_id, utc_now()),
        )
    con.commit()
    return digest


def cmd_schema_init(args):
    path = db_path(args)
    if args.reset:
        remove_sqlite_files(path)
    con = connect(path)
    apply_schema(con)
    incumbent_digest = ""
    if args.seed_connector:
        incumbent_digest = seed_connector(con, args)
    emit(
        {
            "ok": True,
            "database_path": str(path),
            "seeded_connector": bool(args.seed_connector),
            "seeded_job": bool(args.seed_job),
            "connector_id": args.connector_id,
            "incumbent_schema_digest": incumbent_digest,
            "foreign_key_check_clean": not foreign_key_check_clean(con),
        }
    )


def replacement_generation(connector_type, digest):
    stamp = utc_now().replace(":", "").replace("-", "")
    return f"{connector_type}-{stamp}-{digest[:12]}"


def build_replacement_report(con, connector_id, requested_type, requested_digest, exit_status, error):
    current = connector_row(con, connector_id)
    fk_clean = not foreign_key_check_clean(con)
    return {
        "connector_id": connector_id,
        "requested_type": requested_type,
        "stored_type": current["connector_type"] if current else "",
        "schema_digest": current["schema_digest"] if current else "",
        "requested_schema_digest": requested_digest,
        "replacement_generation": current["immutable_generation"] if current else "",
        "foreign_key_check_clean": fk_clean,
        "command_exit_status": int(exit_status),
        "active_reference_count": int(reference_count(con, connector_id)),
        "error": error,
    }


def cmd_connector_replace(args):
    path = db_path(args)
    requested_digest = schema_digest(args.schema_file)
    exit_status = 0
    error = ""
    con = connect(path)
    apply_schema(con)
    try:
        con.execute("BEGIN IMMEDIATE")
        old = connector_row(con, args.connector_id)
        if old is None:
            raise RuntimeError(f"connector_id not found: {args.connector_id}")
        con.execute("DELETE FROM connector_catalog WHERE connector_id = ?", (args.connector_id,))
        con.execute(
            """
            INSERT INTO connector_catalog(
              connector_id, connector_type, schema_digest, config_contract_version,
              immutable_generation, schema_path, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                args.connector_id,
                args.connector_type,
                requested_digest,
                int(old["config_contract_version"]) + 1,
                replacement_generation(args.connector_type, requested_digest),
                str(pathlib.Path(args.schema_file)),
                utc_now(),
            ),
        )
        con.commit()
    except sqlite3.IntegrityError as exc:
        con.rollback()
        exit_status = 17
        if FOREIGN_KEY_DIAGNOSTIC in str(exc):
            error = f"{FOREIGN_KEY_DIAGNOSTIC}: connector has active dependent export_jobs"
            print(f"ERROR: {error}", file=sys.stderr)
        else:
            error = f"sqlite integrity error: {exc}"
            print(f"ERROR: {error}", file=sys.stderr)
    except Exception as exc:
        con.rollback()
        exit_status = 18
        error = str(exc)
        print(f"ERROR: {error}", file=sys.stderr)
    report = build_replacement_report(con, args.connector_id, args.connector_type, requested_digest, exit_status, error)
    write_report(args.report, report)
    emit(report)
    raise SystemExit(exit_status)


def cmd_connector_show(args):
    path = db_path(args)
    con = connect(path)
    row = connector_row(con, args.connector_id)
    if row is None:
        print(f"ERROR: connector not found: {args.connector_id}", file=sys.stderr)
        raise SystemExit(12)
    payload = row_dict(row)
    payload["database_path"] = str(path)
    payload["active_reference_count"] = reference_count(con, args.connector_id)
    payload["foreign_key_check_clean"] = not foreign_key_check_clean(con)
    emit(payload)


def schema_digest_for_catalog(con):
    rows = con.execute(
        """
        SELECT type, name, tbl_name, sql
        FROM sqlite_master
        WHERE type IN ('table', 'index', 'trigger') AND name NOT LIKE 'sqlite_%'
        ORDER BY type, name
        """
    ).fetchall()
    text = "\n".join("|".join("" if value is None else str(value) for value in row) for row in rows)
    return hashlib.sha256(text.encode("utf-8")).hexdigest(), text


def cmd_catalog_snapshot(args):
    path = db_path(args)
    con = connect(path)
    digest, schema_text = schema_digest_for_catalog(con)
    connectors = [
        row_dict(row)
        for row in con.execute(
            """
            SELECT connector_id, connector_type, schema_digest, config_contract_version,
                   immutable_generation, schema_path, created_at
            FROM connector_catalog ORDER BY connector_id
            """
        )
    ]
    jobs = [
        row_dict(row)
        for row in con.execute(
            """
            SELECT job_id, connector_id, state, checkpoint_batch, rows_exported,
                   output_path, claimed_by, last_update
            FROM export_jobs ORDER BY job_id
            """
        )
    ]
    checkpoints = [
        row_dict(row)
        for row in con.execute(
            """
            SELECT job_id, last_batch, rows_exported, artifact_digest, updated_at
            FROM job_checkpoint ORDER BY job_id
            """
        )
    ]
    emit(
        {
            "ok": True,
            "database_path": str(path),
            "schema_digest": digest,
            "schema_text": schema_text,
            "foreign_keys_enabled": con.execute("PRAGMA foreign_keys").fetchone()[0],
            "foreign_key_check": foreign_key_check_clean(con),
            "connectors": connectors,
            "export_jobs": jobs,
            "job_checkpoint": checkpoints,
        }
    )


def build_parser():
    parser = argparse.ArgumentParser(prog="catalog-admin")
    sub = parser.add_subparsers(dest="area", required=True)

    schema = sub.add_parser("schema")
    schema_sub = schema.add_subparsers(dest="command", required=True)
    init = schema_sub.add_parser("init")
    init.add_argument("--db", default="")
    init.add_argument("--reset", action="store_true")
    init.add_argument("--seed-connector", action="store_true")
    init.add_argument("--seed-job", action="store_true")
    init.add_argument("--connector-id", default="analytics_events_primary")
    init.add_argument("--connector-type", default="warehouse_events_v1")
    init.add_argument("--incumbent-schema", required=True)
    init.add_argument("--job-id", default="export_20260726_analytics_017")
    init.add_argument("--job-output", default="/work/export_outputs/export_20260726_analytics_017.jsonl")
    init.set_defaults(func=cmd_schema_init)

    connector = sub.add_parser("connector")
    connector_sub = connector.add_subparsers(dest="command", required=True)
    replace = connector_sub.add_parser("replace")
    replace.add_argument("--db", default="")
    replace.add_argument("--connector-id", required=True)
    replace.add_argument("--connector-type", required=True)
    replace.add_argument("--schema-file", required=True)
    replace.add_argument("--report", default="")
    replace.set_defaults(func=cmd_connector_replace)
    show = connector_sub.add_parser("show")
    show.add_argument("--db", default="")
    show.add_argument("--connector-id", required=True)
    show.set_defaults(func=cmd_connector_show)

    catalog = sub.add_parser("catalog")
    catalog_sub = catalog.add_subparsers(dest="command", required=True)
    snapshot = catalog_sub.add_parser("snapshot")
    snapshot.add_argument("--db", default="")
    snapshot.set_defaults(func=cmd_catalog_snapshot)
    return parser


def main():
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
