#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import sqlite3
import sys


GUIDE = {
    "doc_key": "SDK-RETRY-204",
    "slug": "python-sdk-idempotent-retries",
    "title": "Python SDK idempotent retry budget",
    "body": "Configure an idempotency key, cap the retry budget at four attempts, and use exponential backoff for request timeout failures.",
    "status": "published",
    "published_at": "2026-08-04T03:52:00Z",
}
AUDIT = {
    "event_id": "PUB-SDK-RETRY-204",
    "action": "developer_guide_published",
    "actor": "sdk-docs-pipeline",
    "recorded_at": "2026-08-04T03:52:00Z",
}


def error_identity(error):
    code = getattr(error, "sqlite_errorcode", None)
    name = getattr(error, "sqlite_errorname", None)
    if code is None and isinstance(error, sqlite3.OperationalError) and str(error).strip().lower() == "database is locked":
        return 5, "SQLITE_BUSY"
    return code, name


def write_receipt(path, payload):
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def main():
    default_root = pathlib.Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", default=str(default_root / "catalog.sqlite3"))
    parser.add_argument("--receipt", default=str(default_root / "retry_guide_receipt.json"))
    parser.add_argument("--busy-timeout-ms", type=int, default=1200)
    args = parser.parse_args()
    database = pathlib.Path(args.database)
    receipt = pathlib.Path(args.receipt)
    receipt.unlink(missing_ok=True)
    connection = sqlite3.connect(database, timeout=args.busy_timeout_ms / 1000)
    connection.execute(f"PRAGMA busy_timeout={args.busy_timeout_ms}")
    try:
        connection.execute("BEGIN IMMEDIATE")
        cursor = connection.execute(
            "INSERT INTO documents(doc_key,slug,title,body,status,published_at) VALUES (:doc_key,:slug,:title,:body,:status,:published_at)",
            GUIDE,
        )
        doc_id = cursor.lastrowid
        connection.execute(
            "INSERT INTO docs_search(rowid,title,body) VALUES (?,?,?)",
            (doc_id, GUIDE["title"], GUIDE["body"]),
        )
        connection.execute(
            "INSERT INTO publication_audit(event_id,doc_key,action,actor,recorded_at) VALUES (:event_id,:doc_key,:action,:actor,:recorded_at)",
            {**AUDIT, "doc_key": GUIDE["doc_key"]},
        )
        connection.commit()
    except sqlite3.Error as error:
        connection.rollback()
        code, name = error_identity(error)
        print(json.dumps({
            "ok": False,
            "sqlite_error_code": code,
            "sqlite_error_name": name,
            "message": str(error),
        }, sort_keys=True), file=sys.stderr)
        return 75
    finally:
        connection.close()
    verify = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=2)
    try:
        document = verify.execute(
            "SELECT doc_id,doc_key,slug,title,body,status,published_at FROM documents WHERE doc_key=?",
            (GUIDE["doc_key"],),
        ).fetchone()
        audit = verify.execute(
            "SELECT event_id,doc_key,action,actor,recorded_at FROM publication_audit WHERE doc_key=?",
            (GUIDE["doc_key"],),
        ).fetchone()
        search_ids = [row[0] for row in verify.execute(
            "SELECT rowid FROM docs_search WHERE docs_search MATCH 'idempotent AND retry AND budget'"
        ).fetchall()]
    finally:
        verify.close()
    expected_document = (doc_id, *GUIDE.values())
    expected_audit = (AUDIT["event_id"], GUIDE["doc_key"], AUDIT["action"], AUDIT["actor"], AUDIT["recorded_at"])
    if document != expected_document or audit != expected_audit or doc_id not in search_ids:
        print("fresh-connection publication verification failed", file=sys.stderr)
        return 1
    write_receipt(receipt, {
        "ok": True,
        "database_inode": database.stat().st_ino,
        "doc_id": doc_id,
        "doc_key": GUIDE["doc_key"],
        "audit_event_id": AUDIT["event_id"],
        "search_query": "idempotent AND retry AND budget",
        "fresh_connection_verified": True,
    })
    print(f"GUIDE_PUBLISHED=1 DOC_KEY={GUIDE['doc_key']} DOC_ID={doc_id} SEARCHABLE=1 RECEIPT={receipt}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
