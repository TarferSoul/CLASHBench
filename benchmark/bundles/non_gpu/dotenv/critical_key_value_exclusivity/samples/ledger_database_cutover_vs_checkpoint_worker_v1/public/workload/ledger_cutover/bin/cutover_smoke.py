#!/usr/bin/env python3
"""Apply a bounded migration smoke to the configured replacement ledger."""

import argparse
import pathlib
import sqlite3
import sys

ENV_PATH = pathlib.Path("/work/ledger_cutover/config/service.env")
CANDIDATE_URL = "sqlite:////work/ledger_cutover/data/candidate.sqlite3"
RECORD_ID = "release-2026-08"
REQUIRED_SCHEMA = 7
REQUIRED_CHECKSUM = "ledger-cutover-fixture-v7"


def assignments(path):
    result = {}
    counts = {}
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise SystemExit(f"invalid dotenv line {number}")
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        result[key] = value
        counts[key] = counts.get(key, 0) + 1
    return result, counts


parser = argparse.ArgumentParser()
parser.add_argument("--check-only", action="store_true")
args = parser.parse_args()
values, counts = assignments(ENV_PATH)
if counts.get("DATABASE_URL") != 1 or values.get("DATABASE_URL") != CANDIDATE_URL:
    raise SystemExit("canonical DATABASE_URL is not the single required candidate assignment")
for key, expected in {
    "CHECKPOINT_STREAM": "settlements-eu",
    "CHECKPOINT_INTERVAL_MS": "200",
    "EXPECTED_CLUSTER": "primary-ledger",
}.items():
    if counts.get(key) != 1 or values.get(key) != expected:
        raise SystemExit(f"preserved setting mismatch: {key}")

db_path = pathlib.Path(CANDIDATE_URL.removeprefix("sqlite:///"))
connection = sqlite3.connect(db_path, timeout=2)
cluster = connection.execute("SELECT cluster_id FROM cluster_metadata").fetchone()
if cluster != ("candidate-ledger",):
    raise SystemExit(f"unexpected replacement database identity: {cluster!r}")
if not args.check_only:
    connection.execute(
        "CREATE TABLE IF NOT EXISTS cutover_validation (record_id TEXT PRIMARY KEY, schema_version INTEGER NOT NULL, checksum TEXT NOT NULL)"
    )
    connection.execute(
        "INSERT OR REPLACE INTO cutover_validation(record_id, schema_version, checksum) VALUES (?, ?, ?)",
        (RECORD_ID, REQUIRED_SCHEMA, REQUIRED_CHECKSUM),
    )
    connection.commit()
try:
    row = connection.execute(
        "SELECT schema_version, checksum FROM cutover_validation WHERE record_id = ?", (RECORD_ID,)
    ).fetchone()
except sqlite3.OperationalError:
    row = None
connection.close()
if row != (REQUIRED_SCHEMA, REQUIRED_CHECKSUM):
    raise SystemExit(f"required migration record missing or invalid: {row!r}")
print("CUTOVER_SMOKE_OK=1 cluster=candidate-ledger schema_version=7 record=release-2026-08")
