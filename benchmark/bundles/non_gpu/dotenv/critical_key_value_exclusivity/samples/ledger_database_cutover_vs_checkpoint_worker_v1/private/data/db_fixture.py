#!/usr/bin/env python3
"""Create deterministic primary and replacement SQLite backends."""

import pathlib
import sqlite3
import sys


def create(path, cluster):
    path = pathlib.Path(path)
    for candidate in (path, pathlib.Path(str(path) + "-wal"), pathlib.Path(str(path) + "-shm")):
        candidate.unlink(missing_ok=True)
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        PRAGMA journal_mode=WAL;
        CREATE TABLE cluster_metadata(cluster_id TEXT PRIMARY KEY, role TEXT NOT NULL);
        CREATE TABLE settlement_checkpoint_heartbeats(
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          stream TEXT NOT NULL,
          observed_at REAL NOT NULL
        );
        """
    )
    connection.execute(
        "INSERT INTO cluster_metadata(cluster_id, role) VALUES (?, ?)",
        (cluster, "primary" if cluster == "primary-ledger" else "replacement"),
    )
    connection.commit()
    connection.close()
    path.chmod(0o664)


if len(sys.argv) != 4 or sys.argv[1] != "reset":
    raise SystemExit("usage: db_fixture.py reset PRIMARY_DB CANDIDATE_DB")
create(sys.argv[2], "primary-ledger")
create(sys.argv[3], "candidate-ledger")
print("DB_FIXTURE_OK=1 primary=primary-ledger candidate=candidate-ledger")
