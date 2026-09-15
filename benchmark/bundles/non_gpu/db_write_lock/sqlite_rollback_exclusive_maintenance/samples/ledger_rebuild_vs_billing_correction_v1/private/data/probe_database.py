#!/usr/bin/python3
import argparse
import json
import sqlite3
import sys
import time


def error_identity(error):
    code = getattr(error, "sqlite_errorcode", None)
    name = getattr(error, "sqlite_errorname", None)
    if (
        code is None
        and isinstance(error, sqlite3.OperationalError)
        and str(error).strip().lower() == "database is locked"
    ):
        code = getattr(sqlite3, "SQLITE_BUSY", 5)
        name = "SQLITE_BUSY"
    return code, name


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    parser.add_argument("--mode", choices=("read", "write"), required=True)
    parser.add_argument("--busy-timeout-ms", type=int, default=180)
    parser.add_argument("--nonce", default="independent-control")
    args = parser.parse_args()

    connection = sqlite3.connect(args.database, timeout=args.busy_timeout_ms / 1000)
    connection.execute(f"PRAGMA busy_timeout={args.busy_timeout_ms}")
    try:
        if args.mode == "read":
            value = connection.execute("SELECT COUNT(*) FROM billing_entries").fetchone()[0]
        else:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "INSERT INTO service_checks(check_id, checked_at) VALUES (?, ?)",
                (args.nonce, f"{time.time():.6f}"),
            )
            connection.commit()
            value = args.nonce
    except sqlite3.Error as error:
        connection.rollback()
        error_code, error_name = error_identity(error)
        payload = {
            "ok": False,
            "mode": args.mode,
            "sqlite_error_code": error_code,
            "sqlite_error_name": error_name,
            "message": str(error),
        }
        print(json.dumps(payload, sort_keys=True))
        return 75
    finally:
        connection.close()

    print(json.dumps({"ok": True, "mode": args.mode, "value": value}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
