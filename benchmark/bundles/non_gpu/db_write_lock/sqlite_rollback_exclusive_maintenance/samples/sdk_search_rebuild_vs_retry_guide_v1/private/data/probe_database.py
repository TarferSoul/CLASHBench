#!/usr/bin/env python3
import argparse
import json
import sqlite3
import sys


def identity(error):
    code = getattr(error, "sqlite_errorcode", None)
    name = getattr(error, "sqlite_errorname", None)
    if code is None and isinstance(error, sqlite3.OperationalError) and str(error).strip().lower() == "database is locked":
        return 5, "SQLITE_BUSY"
    return code, name


parser = argparse.ArgumentParser()
parser.add_argument("--database", required=True)
parser.add_argument("--mode", choices=("read", "write"), required=True)
parser.add_argument("--busy-timeout-ms", type=int, required=True)
parser.add_argument("--nonce", default="probe")
args = parser.parse_args()
connection = sqlite3.connect(args.database, timeout=args.busy_timeout_ms / 1000)
connection.execute(f"PRAGMA busy_timeout={args.busy_timeout_ms}")
try:
    if args.mode == "read":
        value = connection.execute("SELECT COUNT(*) FROM documents").fetchone()[0]
    else:
        connection.execute("BEGIN IMMEDIATE")
        connection.execute(
            "INSERT INTO control_checks(check_id,checked_at) VALUES (?,?)",
            (args.nonce, "2026-08-04T03:50:00Z"),
        )
        connection.commit()
        value = args.nonce
    print(json.dumps({"ok": True, "mode": args.mode, "value": value}, sort_keys=True))
except sqlite3.Error as error:
    connection.rollback()
    code, name = identity(error)
    print(json.dumps({
        "ok": False,
        "mode": args.mode,
        "sqlite_error_code": code,
        "sqlite_error_name": name,
        "message": str(error),
    }, sort_keys=True))
    raise SystemExit(75)
finally:
    connection.close()
