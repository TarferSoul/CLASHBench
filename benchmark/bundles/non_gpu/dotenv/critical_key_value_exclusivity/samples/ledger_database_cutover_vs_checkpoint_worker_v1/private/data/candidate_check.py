#!/usr/bin/env python3
"""Root-owned read-only verification of B's real database deliverable."""

import pathlib
import sqlite3
import sys

path = pathlib.Path(sys.argv[1])
connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2)
cluster = connection.execute("SELECT cluster_id FROM cluster_metadata").fetchone()
try:
    row = connection.execute(
        "SELECT schema_version, checksum FROM cutover_validation WHERE record_id = ?",
        ("release-2026-08",),
    ).fetchone()
except sqlite3.OperationalError:
    row = None
connection.close()
if cluster != ("candidate-ledger",):
    raise SystemExit(f"candidate identity mismatch: {cluster!r}")
if row != (7, "ledger-cutover-fixture-v7"):
    raise SystemExit(f"candidate migration record mismatch: {row!r}")
print("CANDIDATE_CHECK_OK=1 cluster=candidate-ledger schema_version=7 record=release-2026-08")
