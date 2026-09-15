#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import signal
import sqlite3
import sys
import time
import traceback


stopping = False


def request_stop(_signum, _frame):
    global stopping
    stopping = True


def write_state(path, payload):
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--migration-id", required=True)
    parser.add_argument("--target-version", required=True, type=int)
    parser.add_argument("--batch-rows", required=True, type=int)
    parser.add_argument("--batch-pause-seconds", required=True, type=float)
    args = parser.parse_args()
    database = pathlib.Path(args.database)
    state_path = pathlib.Path(args.state)
    journal = pathlib.Path(str(database) + "-journal")
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    state = {
        "pid": os.getpid(),
        "migration_id": args.migration_id,
        "phase": "starting",
        "indexed_rows": 0,
        "database_inode": database.stat().st_ino,
        "journal_inode": None,
        "started_epoch": time.time(),
    }
    write_state(state_path, state)
    connection = sqlite3.connect(database, timeout=5, isolation_level=None)
    transaction_active = False
    try:
        mode = connection.execute("PRAGMA journal_mode").fetchone()[0]
        if mode.lower() != "delete":
            raise RuntimeError(f"journal mode changed to {mode}")
        source_rows = connection.execute("SELECT COUNT(*) FROM documents WHERE status='published'").fetchone()[0]
        connection.execute("BEGIN EXCLUSIVE")
        transaction_active = True
        connection.execute(
            "INSERT INTO maintenance_runs(migration_id,target_version,status,source_rows,indexed_rows,started_at,completed_at) "
            "VALUES (?,?,'running',?,0,'2026-08-04T03:48:00Z',NULL)",
            (args.migration_id, args.target_version, source_rows),
        )
        connection.execute("CREATE VIRTUAL TABLE docs_search_next USING fts5(title, body, tokenize='unicode61', prefix='2 3')")
        state.update(phase="indexing", journal_inode=journal.stat().st_ino)
        write_state(state_path, state)
        indexed = 0
        while indexed < source_rows:
            if stopping:
                raise RuntimeError("search refresh stop requested")
            rows = connection.execute(
                "SELECT doc_id,title,body FROM documents WHERE status='published' ORDER BY doc_id LIMIT ? OFFSET ?",
                (args.batch_rows, indexed),
            ).fetchall()
            if not rows:
                raise RuntimeError(f"published source ended at {indexed} of {source_rows}")
            connection.executemany(
                "INSERT INTO docs_search_next(rowid,title,body) VALUES (?,?,?)",
                rows,
            )
            indexed += len(rows)
            connection.execute(
                "UPDATE maintenance_runs SET indexed_rows=? WHERE migration_id=?",
                (indexed, args.migration_id),
            )
            state["indexed_rows"] = indexed
            write_state(state_path, state)
            time.sleep(args.batch_pause_seconds)
        state.update(phase="validating")
        write_state(state_path, state)
        target_rows = connection.execute("SELECT COUNT(*) FROM docs_search_next").fetchone()[0]
        timeout_hits = connection.execute(
            "SELECT COUNT(*) FROM docs_search_next WHERE docs_search_next MATCH 'request AND timeout'"
        ).fetchone()[0]
        if target_rows != source_rows or timeout_hits < 100:
            raise RuntimeError(f"index validation failed rows={target_rows}/{source_rows} timeout_hits={timeout_hits}")
        state.update(phase="publishing", timeout_query_hits=timeout_hits)
        write_state(state_path, state)
        connection.execute("DROP TABLE docs_search")
        connection.execute("ALTER TABLE docs_search_next RENAME TO docs_search")
        connection.execute(f"PRAGMA user_version={args.target_version}")
        connection.execute(
            "UPDATE maintenance_runs SET status='committed',indexed_rows=?,completed_at='2026-08-04T03:54:00Z' WHERE migration_id=?",
            (indexed, args.migration_id),
        )
        connection.commit()
        transaction_active = False
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        if integrity != "ok" or version != args.target_version:
            raise RuntimeError(f"post-commit validation failed integrity={integrity} version={version}")
        state.update(
            phase="committed",
            indexed_rows=indexed,
            integrity_check=integrity,
            committed_version=version,
            completed_epoch=time.time(),
        )
        write_state(state_path, state)
        print(f"SEARCH_REFRESH_COMMITTED=1 MIGRATION_ID={args.migration_id} INDEXED={indexed} USER_VERSION={version} INTEGRITY={integrity}")
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
