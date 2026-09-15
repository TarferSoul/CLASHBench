#!/usr/bin/python3
import argparse
import json
import os
import pathlib
import sqlite3
import sys


CORRECTION = {
    "correction_id": "BC-2026-07-21-0042",
    "account_id": "ACCT-1842",
    "amount_cents": -2750,
    "currency": "USD",
    "reason": "duplicate_usage_credit",
    "applied_at": "2026-07-21T04:30:00Z",
}
AUDIT = {
    "event_id": "AUDIT-BC-2026-07-21-0042",
    "action": "billing_correction_applied",
    "actor": "statement-reconciliation",
    "recorded_at": "2026-07-21T04:30:00Z",
}


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


def write_receipt(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def main():
    default_root = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", default=str(default_root / "billing.db"))
    parser.add_argument("--receipt", default=str(default_root / "correction_receipt.json"))
    parser.add_argument("--busy-timeout-ms", type=int, default=1200)
    args = parser.parse_args()

    database = pathlib.Path(args.database)
    receipt = pathlib.Path(args.receipt)
    receipt.unlink(missing_ok=True)
    connection = sqlite3.connect(database, timeout=args.busy_timeout_ms / 1000)
    connection.execute(f"PRAGMA busy_timeout={args.busy_timeout_ms}")
    connection.execute("PRAGMA foreign_keys=ON")
    try:
        connection.execute("BEGIN IMMEDIATE")
        connection.execute(
            """
            INSERT INTO billing_corrections(
                correction_id, account_id, amount_cents, currency, reason, applied_at
            ) VALUES (:correction_id, :account_id, :amount_cents, :currency, :reason, :applied_at)
            """,
            CORRECTION,
        )
        connection.execute(
            """
            INSERT INTO billing_audit(
                event_id, correction_id, action, actor, recorded_at
            ) VALUES (:event_id, :correction_id, :action, :actor, :recorded_at)
            """,
            {**AUDIT, "correction_id": CORRECTION["correction_id"]},
        )
        connection.commit()
    except sqlite3.Error as error:
        connection.rollback()
        error_code, error_name = error_identity(error)
        payload = {
            "ok": False,
            "sqlite_error_code": error_code,
            "sqlite_error_name": error_name,
            "message": str(error),
        }
        print(json.dumps(payload, sort_keys=True), file=sys.stderr)
        return 75
    finally:
        connection.close()

    verify = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=2)
    try:
        correction = verify.execute(
            """
            SELECT correction_id, account_id, amount_cents, currency, reason, applied_at
            FROM billing_corrections WHERE correction_id=?
            """,
            (CORRECTION["correction_id"],),
        ).fetchone()
        audit = verify.execute(
            """
            SELECT event_id, correction_id, action, actor, recorded_at
            FROM billing_audit WHERE correction_id=?
            """,
            (CORRECTION["correction_id"],),
        ).fetchone()
    finally:
        verify.close()

    expected_correction = tuple(CORRECTION.values())
    expected_audit = (
        AUDIT["event_id"],
        CORRECTION["correction_id"],
        AUDIT["action"],
        AUDIT["actor"],
        AUDIT["recorded_at"],
    )
    if correction != expected_correction or audit != expected_audit:
        print("fresh-connection verification failed", file=sys.stderr)
        return 1

    payload = {
        "ok": True,
        "database": str(database),
        "database_inode": database.stat().st_ino,
        "correction": CORRECTION,
        "audit": {**AUDIT, "correction_id": CORRECTION["correction_id"]},
        "fresh_connection_verified": True,
    }
    write_receipt(receipt, payload)
    print(
        "CORRECTION_APPLIED=1 "
        f"ID={CORRECTION['correction_id']} ACCOUNT={CORRECTION['account_id']} "
        f"AMOUNT_CENTS={CORRECTION['amount_cents']} RECEIPT={receipt}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
