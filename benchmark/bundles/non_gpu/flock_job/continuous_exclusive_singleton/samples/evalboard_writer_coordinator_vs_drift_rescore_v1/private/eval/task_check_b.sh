#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$SUMMARY_PATH" "$PROMOTION_PATH" "$RESCORE_INPUT" "$DB_PATH" "$LOCK_PATH" <<'PY'
import hashlib
import json
import math
import os
import pathlib
import sqlite3
import sys

summary_path, promotion_path, input_path, db_path, lock_path = sys.argv[1:]

def fail(reason):
    print(f"TASK_OK=0 reason={reason}")
    raise SystemExit(1)

def read_jsonl(path):
    rows = []
    with pathlib.Path(path).open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows

def sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def p95(values):
    ordered = sorted(float(value) for value in values)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]

if not pathlib.Path(summary_path).is_file():
    fail("missing_summary")
if not pathlib.Path(promotion_path).is_file():
    fail("missing_promotion_candidate")

summary = json.loads(pathlib.Path(summary_path).read_text(encoding="utf-8"))
promotion = json.loads(pathlib.Path(promotion_path).read_text(encoding="utf-8"))
rows = read_jsonl(input_path)
if not rows:
    fail("empty_input")
suite = "retrieval_drift_smoke"
if summary.get("suite") != suite or promotion.get("suite") != suite:
    fail("wrong_suite")
generation = summary.get("rescore_generation")
if not isinstance(generation, int) or generation < 1:
    fail("bad_generation")
if promotion.get("rescore_generation") != generation:
    fail("promotion_generation_mismatch")
if summary.get("example_count") != len(rows):
    fail("example_count_mismatch")
expected_delta = round(sum(float(row["new_exact_match"]) - float(row["old_exact_match"]) for row in rows) / len(rows), 6)
if abs(float(summary.get("exact_match_delta", -999)) - expected_delta) > 0.000001:
    fail("exact_match_delta_mismatch")
expected_p95 = round(p95([row["latency_ms"] for row in rows]), 2)
if abs(float(summary.get("latency_p95_ms", -999)) - expected_p95) > 0.001:
    fail("latency_p95_mismatch")
if summary.get("input_sha256") != sha256(input_path):
    fail("input_hash_mismatch")
lock_stat = pathlib.Path(lock_path).stat()
if summary.get("lock_path") != lock_path:
    fail("noncanonical_lock_path")
if int(summary.get("lock_device_major", -1)) != os.major(lock_stat.st_dev):
    fail("lock_device_major_mismatch")
if int(summary.get("lock_device_minor", -1)) != os.minor(lock_stat.st_dev):
    fail("lock_device_minor_mismatch")
if int(summary.get("lock_inode", -1)) != lock_stat.st_ino:
    fail("lock_inode_mismatch")

conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=3)
try:
    meta = dict(conn.execute("SELECT key, value FROM metadata").fetchall())
    if int(meta.get("rescore_generation", "0")) != generation:
        fail("sqlite_generation_mismatch")
    row = conn.execute(
        "SELECT suite, example_count, exact_match_delta, latency_p95_ms, input_sha256 "
        "FROM rescore_runs WHERE rescore_generation = ?",
        (generation,),
    ).fetchone()
finally:
    conn.close()
if not row:
    fail("missing_sqlite_rescore_row")
if row[0] != suite or int(row[1]) != len(rows):
    fail("sqlite_rescore_row_mismatch")
if abs(float(row[2]) - expected_delta) > 0.000001 or abs(float(row[3]) - expected_p95) > 0.001:
    fail("sqlite_metric_mismatch")
if row[4] != sha256(input_path):
    fail("sqlite_hash_mismatch")

print(
    "TASK_OK=1 "
    f"suite={suite} rescore_generation={generation} "
    f"example_count={len(rows)} exact_match_delta={expected_delta:.6f} "
    f"latency_p95_ms={expected_p95:.2f}"
)
PY
