#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import signal
import sqlite3
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--db", required=True)
parser.add_argument("--status", required=True)
parser.add_argument("--batch-id", required=True)
parser.add_argument("--generation", required=True)
args = parser.parse_args()

publish_requested = False

def request_publish(_signum, _frame):
    global publish_requested
    publish_requested = True

signal.signal(signal.SIGUSR1, request_publish)

def write_status(**fields):
    payload = {
        "pid": os.getpid(),
        "batch_id": args.batch_id,
        "candidate_generation": args.generation,
        "updated_at": time.time(),
        **fields,
    }
    fd, tmp = tempfile.mkstemp(prefix=".index-status-", dir=os.path.dirname(args.status), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, args.status)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

conn = sqlite3.connect(args.db, timeout=1, isolation_level=None)
conn.execute("PRAGMA busy_timeout=1000")
conn.execute("PRAGMA foreign_keys=ON")
mode = conn.execute("PRAGMA journal_mode").fetchone()[0].lower()
if mode != "wal":
    raise SystemExit(f"expected WAL, got {mode}")

indexed = 0
digest_checks = 0
catalog_digest = ""
try:
    conn.execute("BEGIN IMMEDIATE")
    while True:
        if indexed < 72:
            row = conn.execute(
                "SELECT package_id,project,version,filename,sha256,dependency_token FROM staged_packages WHERE package_id=?",
                (indexed + 1,),
            ).fetchone()
            package_id, project, version, filename, sha, token = row
            normalized = project.lower().replace("_", "-")
            content_digest = hashlib.sha256(f"{project}|{version}|{filename}|{sha}|{token}".encode()).hexdigest()
            conn.execute(
                "INSERT INTO search_generations(generation,project,version,normalized_name,content_digest) VALUES (?,?,?,?,?)",
                (args.generation, project, version, normalized, content_digest),
            )
            indexed = package_id
        else:
            digests = [r[0] for r in conn.execute(
                "SELECT content_digest FROM search_generations WHERE generation=? ORDER BY project,version",
                (args.generation,),
            )]
            if len(digests) != 72:
                raise RuntimeError("candidate generation is incomplete")
            catalog_digest = hashlib.sha256("".join(digests).encode()).hexdigest()
            digest_checks += 1
        progress_seq = indexed + digest_checks
        write_status(
            phase="active",
            transaction="BEGIN IMMEDIATE",
            journal_mode=mode,
            packages_indexed=indexed,
            digest_checks=digest_checks,
            catalog_digest=catalog_digest,
            progress_seq=progress_seq,
        )
        if publish_requested and indexed == 72 and digest_checks >= 1:
            conn.execute(
                "UPDATE registry_state SET active_generation=?,serial=serial+1 WHERE singleton=1",
                (args.generation,),
            )
            conn.commit()
            write_status(
                phase="committed",
                transaction="released",
                journal_mode=mode,
                packages_indexed=indexed,
                digest_checks=digest_checks,
                catalog_digest=catalog_digest,
                progress_seq=progress_seq,
            )
            break
        time.sleep(0.045)
except BaseException as exc:
    try:
        conn.rollback()
    except Exception:
        pass
    write_status(
        phase="failed",
        transaction="rolled_back",
        journal_mode=mode,
        packages_indexed=indexed,
        digest_checks=digest_checks,
        catalog_digest=catalog_digest,
        progress_seq=indexed + digest_checks,
        error=type(exc).__name__,
    )
    raise
finally:
    conn.close()
