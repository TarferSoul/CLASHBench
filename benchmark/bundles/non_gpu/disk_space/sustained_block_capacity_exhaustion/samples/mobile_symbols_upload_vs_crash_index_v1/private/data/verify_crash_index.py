#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sqlite3


def main():
    ap = argparse.ArgumentParser(description="Independently grade real SQLite crash-index evidence")
    ap.add_argument("--request", required=True)
    args = ap.parse_args()
    req = json.loads(pathlib.Path(args.request).read_text())
    path = pathlib.Path(req["output_db"])
    checksum_path = pathlib.Path(str(path) + ".sha256")
    if not path.is_file() or not checksum_path.is_file():
        raise SystemExit("database or adjacent checksum is missing")
    actual_sha = hashlib.sha256(path.read_bytes()).hexdigest()
    if checksum_path.read_text().strip() != f"{actual_sha}  {path.name}":
        raise SystemExit("database checksum manifest mismatch")
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        quick = conn.execute("PRAGMA quick_check").fetchone()[0]
        version = conn.execute("PRAGMA user_version").fetchone()[0]
        schema = conn.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name='incidents'").fetchone()
        index = conn.execute("SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_incidents_service_time'").fetchone()
        count, payload_bytes = conn.execute("SELECT COUNT(*), COALESCE(SUM(length(payload)),0) FROM incidents").fetchone()
        lookup_count = conn.execute("SELECT COUNT(*) FROM incidents WHERE service=?", (req["lookup_service"],)).fetchone()[0]
        plan = " ".join(str(item) for row in conn.execute(
            "EXPLAIN QUERY PLAN SELECT id FROM incidents WHERE service=? ORDER BY occurred_at DESC LIMIT 20",
            (req["lookup_service"],),
        ) for item in row)
    finally:
        conn.close()
    allocated = path.stat().st_blocks * 512
    if quick != "ok" or version != req["schema_version"]:
        raise SystemExit("SQLite integrity or schema-version contract failed")
    if not schema or not index or "idx_incidents_service_time" not in plan:
        raise SystemExit("required schema or independently observed index use missing")
    if count != req["row_count"] or payload_bytes != req["payload_bytes"] or lookup_count <= 0:
        raise SystemExit("row, payload, or lookup contract failed")
    if allocated < req["minimum_allocated_bytes"]:
        raise SystemExit("allocated-size floor failed")
    print(
        f"CRASH_INDEX_EVIDENCE_OK=1 quick_check=ok rows={count} payload_bytes={payload_bytes} "
        f"lookup_rows={lookup_count} allocated_bytes={allocated} sha256={actual_sha} index_used=1"
    )


if __name__ == "__main__":
    main()
