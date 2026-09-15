#!/usr/bin/env python3
import argparse
import pathlib
import sqlite3


def documents(total):
    topics = ("authentication", "pagination", "request timeout", "webhook signature", "streaming")
    for doc_id in range(1, total + 1):
        topic = topics[doc_id % len(topics)]
        yield (
            doc_id,
            f"SDK-AUTO-{doc_id:06d}",
            f"python-{topic.replace(' ', '-')}-{doc_id:06d}",
            f"Python SDK {topic} reference {doc_id:06d}",
            f"Generated developer reference for {topic}. Example {doc_id:06d} covers client configuration, errors, and tests.",
            "published",
            "2026-07-15T00:00:00Z",
        )


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
            raise RuntimeError(f"unexpected journal mode {mode}")
        connection.execute("PRAGMA synchronous=FULL")
        connection.executescript(
            """
            CREATE TABLE documents (
                doc_id INTEGER PRIMARY KEY,
                doc_key TEXT NOT NULL UNIQUE,
                slug TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('draft','published')),
                published_at TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE docs_search USING fts5(title, body, tokenize='unicode61');
            CREATE TABLE publication_audit (
                event_id TEXT PRIMARY KEY,
                doc_key TEXT NOT NULL UNIQUE,
                action TEXT NOT NULL,
                actor TEXT NOT NULL,
                recorded_at TEXT NOT NULL
            );
            CREATE TABLE maintenance_runs (
                migration_id TEXT PRIMARY KEY,
                target_version INTEGER NOT NULL,
                status TEXT NOT NULL,
                source_rows INTEGER NOT NULL,
                indexed_rows INTEGER NOT NULL,
                started_at TEXT NOT NULL,
                completed_at TEXT
            );
            CREATE TABLE control_checks (
                check_id TEXT PRIMARY KEY,
                checked_at TEXT NOT NULL
            );
            """
        )
        insert_document = (
            "INSERT INTO documents(doc_id,doc_key,slug,title,body,status,published_at) "
            "VALUES (?,?,?,?,?,?,?)"
        )
        batch = []
        for row in documents(args.rows):
            batch.append(row)
            if len(batch) == 1000:
                connection.executemany(insert_document, batch)
                connection.executemany(
                    "INSERT INTO docs_search(rowid,title,body) VALUES (?,?,?)",
                    [(item[0], item[3], item[4]) for item in batch],
                )
                batch.clear()
        if batch:
            connection.executemany(insert_document, batch)
            connection.executemany(
                "INSERT INTO docs_search(rowid,title,body) VALUES (?,?,?)",
                [(item[0], item[3], item[4]) for item in batch],
            )
        connection.execute("PRAGMA user_version=7")
        connection.commit()
        count = connection.execute("SELECT COUNT(*) FROM documents").fetchone()[0]
        indexed = connection.execute("SELECT COUNT(*) FROM docs_search").fetchone()[0]
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if (count, indexed, integrity) != (args.rows, args.rows, "ok"):
            raise RuntimeError(f"seed verification failed count={count} indexed={indexed} integrity={integrity}")
    finally:
        connection.close()
    database.chmod(0o660)
    print(f"SEEDED=1 DATABASE={database} DOCUMENTS={args.rows} INDEXED={args.rows} JOURNAL_MODE=delete USER_VERSION=7")


if __name__ == "__main__":
    main()
