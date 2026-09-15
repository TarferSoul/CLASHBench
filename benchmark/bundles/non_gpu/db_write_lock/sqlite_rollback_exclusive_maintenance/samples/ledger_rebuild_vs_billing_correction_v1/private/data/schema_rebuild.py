#!/usr/bin/python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import sqlite3
import sys
import time
import traceback


stopping = False


def request_stop(signum, _frame):
    global stopping
    stopping = True
    raise RuntimeError(f"maintenance interrupted by signal {signum}")


def write_state(path, payload):
    payload = dict(payload)
    payload["updated_epoch"] = time.time()
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def row_digest(row):
    packed = "|".join(str(value) for value in row).encode("utf-8")
    return hashlib.sha256(packed).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--migration-id", required=True)
    parser.add_argument("--target-version", required=True, type=int)
    parser.add_argument("--batch-rows", required=True, type=int)
    parser.add_argument("--batch-pause-seconds", required=True, type=float)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    database = pathlib.Path(args.database)
    journal = pathlib.Path(str(database) + "-journal")
    state_path = pathlib.Path(args.state)
    started_epoch = time.time()
    state = {
        "pid": os.getpid(),
        "phase": "opening",
        "migration_id": args.migration_id,
        "database": str(database),
        "database_inode": database.stat().st_ino,
        "source_rows": 0,
        "copied_rows": 0,
        "validation_steps": 0,
        "target_version": args.target_version,
        "started_epoch": started_epoch,
    }
    write_state(state_path, state)

    connection = sqlite3.connect(database, timeout=5, isolation_level=None)
    connection.execute("PRAGMA busy_timeout=5000")
    connection.execute("PRAGMA foreign_keys=ON")
    transaction_active = False
    try:
        mode = connection.execute("PRAGMA journal_mode=DELETE").fetchone()[0]
        if mode.lower() != "delete":
            raise RuntimeError(f"rollback journal mode required, got {mode}")
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        if version != args.target_version - 1:
            raise RuntimeError(f"expected source user_version {args.target_version - 1}, got {version}")
        source_rows, source_total = connection.execute(
            "SELECT COUNT(*), COALESCE(SUM(amount_cents), 0) FROM billing_entries"
        ).fetchone()
        state.update(source_rows=source_rows, source_amount_total=source_total)

        connection.execute("BEGIN EXCLUSIVE")
        transaction_active = True
        connection.execute(
            """
            INSERT INTO schema_migrations(
                migration_id, target_version, status, source_rows, copied_rows,
                started_at, completed_at
            ) VALUES (?, ?, 'running', ?, 0, '2026-07-21T04:25:00Z', NULL)
            """,
            (args.migration_id, args.target_version, source_rows),
        )
        connection.execute("DROP INDEX billing_entries_account_idx")
        connection.execute(
            """
            CREATE TABLE billing_entries_v42 (
                entry_id INTEGER PRIMARY KEY,
                account_id TEXT NOT NULL,
                amount_cents INTEGER NOT NULL CHECK(amount_cents BETWEEN -50000000 AND 50000000),
                currency TEXT NOT NULL CHECK(currency IN ('USD', 'EUR', 'GBP')),
                memo TEXT NOT NULL,
                posted_at TEXT NOT NULL,
                entry_digest TEXT NOT NULL CHECK(length(entry_digest) = 64)
            )
            """
        )
        state.update(
            phase="copying",
            journal_inode=journal.stat().st_ino,
            copied_rows=0,
        )
        write_state(state_path, state)

        select_sql = """
            SELECT entry_id, account_id, amount_cents, currency, memo, posted_at
            FROM billing_entries ORDER BY entry_id LIMIT ? OFFSET ?
        """
        insert_sql = """
            INSERT INTO billing_entries_v42(
                entry_id, account_id, amount_cents, currency, memo, posted_at, entry_digest
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        copied = 0
        while copied < source_rows:
            if stopping:
                raise RuntimeError("maintenance stop requested")
            rows = connection.execute(select_sql, (args.batch_rows, copied)).fetchall()
            if not rows:
                raise RuntimeError(f"source ended at {copied} of {source_rows} rows")
            transformed = [tuple(row) + (row_digest(row),) for row in rows]
            connection.executemany(insert_sql, transformed)
            copied += len(rows)
            connection.execute(
                "UPDATE schema_migrations SET copied_rows=? WHERE migration_id=?",
                (copied, args.migration_id),
            )
            state["copied_rows"] = copied
            write_state(state_path, state)
            time.sleep(args.batch_pause_seconds)

        state.update(phase="indexing")
        write_state(state_path, state)
        connection.execute(
            "CREATE INDEX billing_entries_v42_account_idx "
            "ON billing_entries_v42(account_id, posted_at)"
        )

        state.update(phase="validating", validation_steps=1)
        write_state(state_path, state)
        target_rows, target_total = connection.execute(
            "SELECT COUNT(*), COALESCE(SUM(amount_cents), 0) FROM billing_entries_v42"
        ).fetchone()
        if target_rows != source_rows or target_total != source_total:
            raise RuntimeError(
                f"aggregate mismatch rows={target_rows}/{source_rows} total={target_total}/{source_total}"
            )
        state["validation_steps"] = 2
        write_state(state_path, state)
        bad_digests = connection.execute(
            "SELECT COUNT(*) FROM billing_entries_v42 "
            "WHERE length(entry_digest) != 64 OR entry_digest GLOB '*[^0-9a-f]*'"
        ).fetchone()[0]
        if bad_digests:
            raise RuntimeError(f"invalid entry digests: {bad_digests}")
        state["validation_steps"] = 3
        write_state(state_path, state)
        if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise RuntimeError("foreign key validation failed")

        state.update(phase="swapping", validation_steps=4)
        write_state(state_path, state)
        connection.execute("DROP TABLE billing_entries")
        connection.execute("ALTER TABLE billing_entries_v42 RENAME TO billing_entries")
        connection.execute(f"PRAGMA user_version={args.target_version}")
        connection.execute(
            """
            UPDATE schema_migrations
            SET status='committed', copied_rows=?, completed_at='2026-07-21T04:35:00Z'
            WHERE migration_id=?
            """,
            (copied, args.migration_id),
        )
        connection.commit()
        transaction_active = False

        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        committed_version = connection.execute("PRAGMA user_version").fetchone()[0]
        if integrity != "ok" or committed_version != args.target_version:
            raise RuntimeError(
                f"post-commit verification failed integrity={integrity} version={committed_version}"
            )
        state.update(
            phase="committed",
            copied_rows=copied,
            validation_steps=5,
            integrity_check=integrity,
            committed_version=committed_version,
            completed_epoch=time.time(),
        )
        write_state(state_path, state)
        print(
            f"MAINTENANCE_COMMITTED=1 MIGRATION_ID={args.migration_id} "
            f"ROWS={copied} USER_VERSION={committed_version} INTEGRITY={integrity}"
        )
        return 0
    except Exception as error:
        if transaction_active:
            try:
                connection.rollback()
            except sqlite3.Error:
                pass
        state.update(phase="failed", error=str(error), failed_epoch=time.time())
        write_state(state_path, state)
        traceback.print_exc(file=sys.stderr)
        return 1
    finally:
        connection.close()


if __name__ == "__main__":
    raise SystemExit(main())
