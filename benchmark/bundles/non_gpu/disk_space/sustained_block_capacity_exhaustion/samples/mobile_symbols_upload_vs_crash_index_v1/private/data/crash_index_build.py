#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import sqlite3
import sys


SERVICES = ("checkout-api", "auth-api", "catalog-worker", "mobile-gateway")


def load_request(path):
    req = json.loads(pathlib.Path(path).read_text())
    required = {"index_id", "seed", "output_db", "row_count", "payload_bytes", "minimum_allocated_bytes", "lookup_service", "schema_version"}
    if not required.issubset(req):
        raise ValueError("request is missing required fields")
    if req["lookup_service"] not in SERVICES:
        raise ValueError("lookup service is unsupported")
    return req


def payload(seed, row_id, size):
    digest = hashlib.sha256(f"{seed}:{row_id}".encode()).digest()
    block = digest * ((size + len(digest) - 1) // len(digest))
    return block[:size]


def verify(req):
    path = pathlib.Path(req["output_db"])
    checksum_path = pathlib.Path(str(path) + ".sha256")
    if not path.is_file() or not checksum_path.is_file():
        raise ValueError("database or checksum file missing")
    actual_sha = hashlib.sha256(path.read_bytes()).hexdigest()
    if checksum_path.read_text().strip() != f"{actual_sha}  {path.name}":
        raise ValueError("adjacent SHA-256 manifest mismatch")
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        if conn.execute("PRAGMA quick_check").fetchone()[0] != "ok":
            raise ValueError("SQLite quick_check failed")
        user_version = conn.execute("PRAGMA user_version").fetchone()[0]
        if user_version != req["schema_version"]:
            raise ValueError("schema version mismatch")
        count, payload_bytes = conn.execute("SELECT COUNT(*), COALESCE(SUM(length(payload)),0) FROM incidents").fetchone()
        if count != req["row_count"] or payload_bytes != req["payload_bytes"]:
            raise ValueError("row or payload contract mismatch")
        plan = " ".join(str(item) for row in conn.execute(
            "EXPLAIN QUERY PLAN SELECT id FROM incidents WHERE service=? ORDER BY occurred_at DESC LIMIT 20",
            (req["lookup_service"],),
        ) for item in row)
        if "idx_incidents_service_time" not in plan:
            raise ValueError("required indexed lookup is not used")
    finally:
        conn.close()
    allocated = path.stat().st_blocks * 512
    if allocated < req["minimum_allocated_bytes"]:
        raise ValueError("database allocated-size floor not met")
    print(
        f"VERIFY_OK=1 quick_check=ok rows={count} payload_bytes={payload_bytes} "
        f"allocated_bytes={allocated} sha256={actual_sha} index_used=idx_incidents_service_time"
    )


def build(req):
    output = pathlib.Path(req["output_db"])
    output.parent.mkdir(parents=True, exist_ok=True)
    temp = output.with_name("." + output.name + f".building-{os.getpid()}")
    for path in (output, pathlib.Path(str(output) + ".sha256"), temp, pathlib.Path(str(temp) + "-journal")):
        path.unlink(missing_ok=True)
    base, extra = divmod(req["payload_bytes"], req["row_count"])
    conn = None
    try:
        conn = sqlite3.connect(temp)
        conn.execute("PRAGMA page_size=4096")
        conn.execute("PRAGMA journal_mode=OFF")
        conn.execute("PRAGMA synchronous=FULL")
        conn.execute("CREATE TABLE incidents (id INTEGER PRIMARY KEY, service TEXT NOT NULL, occurred_at INTEGER NOT NULL, stack_hash TEXT NOT NULL, payload BLOB NOT NULL)")
        conn.execute("CREATE INDEX idx_incidents_service_time ON incidents(service, occurred_at DESC)")
        conn.execute(f"PRAGMA user_version={int(req['schema_version'])}")
        conn.execute("BEGIN")
        for row_id in range(req["row_count"]):
            size = base + (1 if row_id < extra else 0)
            service = SERVICES[row_id % len(SERVICES)]
            occurred = 1785753600 + row_id * 17
            stack_hash = hashlib.sha256(f"stack:{row_id % 61}".encode()).hexdigest()
            conn.execute(
                "INSERT INTO incidents(id,service,occurred_at,stack_hash,payload) VALUES(?,?,?,?,?)",
                (row_id + 1, service, occurred, stack_hash, payload(req["seed"], row_id, size)),
            )
        conn.commit()
        conn.close()
        conn = None
        os.replace(temp, output)
        checksum = hashlib.sha256(output.read_bytes()).hexdigest()
        pathlib.Path(str(output) + ".sha256").write_text(f"{checksum}  {output.name}\n")
        verify(req)
        return 0
    except sqlite3.OperationalError as exc:
        if conn is not None:
            try:
                conn.close()
            except sqlite3.Error:
                pass
        for path in (temp, pathlib.Path(str(temp) + "-journal"), output, pathlib.Path(str(output) + ".sha256")):
            path.unlink(missing_ok=True)
        if "full" in str(exc).lower() or "space" in str(exc).lower():
            print(f"CRASH_INDEX_BUILD_FAILED sqlite_code=SQLITE_FULL reason={exc}", file=sys.stderr)
            return 28
        raise
    except OSError as exc:
        if conn is not None:
            conn.close()
        for path in (temp, output, pathlib.Path(str(output) + ".sha256")):
            path.unlink(missing_ok=True)
        if exc.errno == 28:
            print("CRASH_INDEX_BUILD_FAILED errno=28 reason=no_space_left", file=sys.stderr)
            return 28
        raise


def main():
    ap = argparse.ArgumentParser(description="Build or verify the mobile crash-triage SQLite index")
    sub = ap.add_subparsers(dest="mode", required=True)
    for name in ("build", "verify"):
        child = sub.add_parser(name)
        child.add_argument("--request", required=True)
    args = ap.parse_args()
    req = load_request(args.request)
    if args.mode == "verify":
        verify(req)
        return 0
    return build(req)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"VERIFY_OK=0 reason={exc}", file=sys.stderr)
        raise SystemExit(2)
