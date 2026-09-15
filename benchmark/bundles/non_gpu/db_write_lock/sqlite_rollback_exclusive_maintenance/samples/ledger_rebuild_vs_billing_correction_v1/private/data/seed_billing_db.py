#!/usr/bin/python3
import argparse
import pathlib
import sqlite3


def seed_rows(total):
    for entry_id in range(1, total + 1):
        account = f"ACCT-{1000 + (entry_id % 5000):04d}"
        amount = ((entry_id * 7919) % 250000) - 50000
        currency = ("USD", "EUR", "GBP")[entry_id % 3]
        memo = f"usage cycle {1 + (entry_id % 31):02d} item {entry_id:06d}"
        posted = f"2026-06-{1 + (entry_id % 30):02d}T{entry_id % 24:02d}:{entry_id % 60:02d}:00Z"
        yield entry_id, account, amount, currency, memo, posted


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    parser.add_argument("--rows", required=True, type=int)
    args = parser.parse_args()

    database = pathlib.Path(args.database)
    database.parent.mkdir(parents=True, exist_ok=True)
    for suffix in ("", "-journal", "-wal", "-shm"):
        pathlib.Path(str(database) + suffix).unlink(missing_ok=True)

    connection = sqlite3.connect(database)
    try:
        mode = connection.execute("PRAGMA journal_mode=DELETE").fetchone()[0]
        if mode.lower() != "delete":
            raise RuntimeError(f"unexpected journal mode: {mode}")
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("PRAGMA foreign_keys=ON")
        connection.executescript(
            """
            CREATE TABLE billing_entries (
                entry_id INTEGER PRIMARY KEY,
                account_id TEXT NOT NULL,
                amount_cents INTEGER NOT NULL,
                currency TEXT NOT NULL,
                memo TEXT NOT NULL,
                posted_at TEXT NOT NULL
            );
            CREATE INDEX billing_entries_account_idx
                ON billing_entries(account_id, posted_at);
            CREATE TABLE billing_corrections (
                correction_id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                amount_cents INTEGER NOT NULL,
                currency TEXT NOT NULL,
                reason TEXT NOT NULL,
                applied_at TEXT NOT NULL
            );
            CREATE TABLE billing_audit (
                event_id TEXT PRIMARY KEY,
                correction_id TEXT NOT NULL UNIQUE,
                action TEXT NOT NULL,
                actor TEXT NOT NULL,
                recorded_at TEXT NOT NULL,
                FOREIGN KEY(correction_id) REFERENCES billing_corrections(correction_id)
            );
            CREATE TABLE service_checks (
                check_id TEXT PRIMARY KEY,
                checked_at TEXT NOT NULL
            );
            CREATE TABLE schema_migrations (
                migration_id TEXT PRIMARY KEY,
                target_version INTEGER NOT NULL,
                status TEXT NOT NULL,
                source_rows INTEGER NOT NULL,
                copied_rows INTEGER NOT NULL,
                started_at TEXT NOT NULL,
                completed_at TEXT
            );
            """
        )
        statement = """
            INSERT INTO billing_entries(
                entry_id, account_id, amount_cents, currency, memo, posted_at
            ) VALUES (?, ?, ?, ?, ?, ?)
        """
        batch = []
        for row in seed_rows(args.rows):
            batch.append(row)
            if len(batch) == 2000:
                connection.executemany(statement, batch)
                batch.clear()
        if batch:
            connection.executemany(statement, batch)
        connection.execute("PRAGMA user_version=41")
        connection.commit()

        observed = connection.execute("SELECT COUNT(*) FROM billing_entries").fetchone()[0]
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        if observed != args.rows or integrity != "ok" or version != 41:
            raise RuntimeError(
                f"seed verification failed rows={observed} integrity={integrity} version={version}"
            )
    finally:
        connection.close()

    database.chmod(0o660)
    print(f"SEEDED=1 DATABASE={database} ROWS={args.rows} JOURNAL_MODE=delete USER_VERSION=41")


if __name__ == "__main__":
    main()
