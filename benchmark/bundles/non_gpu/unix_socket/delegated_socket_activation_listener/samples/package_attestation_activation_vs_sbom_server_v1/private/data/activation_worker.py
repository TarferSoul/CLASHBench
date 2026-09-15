#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import socket
import sys
import time


def pid_start_ticks(pid):
    return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]


def read_request(conn):
    data = b""
    while b"\n" not in data and len(data) < 65536:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    if not data:
        return {}
    return json.loads(data.split(b"\n", 1)[0].decode("utf-8"))


def write_journal(path, record):
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def response_for(request, catalog, service, api_version, journal_path):
    op = request.get("op")
    if op == "health":
        journal_records = 0
        try:
            journal_records = sum(1 for line in pathlib.Path(journal_path).read_text().splitlines() if line)
        except FileNotFoundError:
            journal_records = 0
        return {
            "ok": True,
            "service": service,
            "api_version": api_version,
            "catalog_entries": len(catalog["features"]),
            "journal_records": journal_records,
        }
    if op == "describe":
        feature = request.get("feature")
        item = catalog["features"].get(feature)
        if item:
            return {
                "ok": True,
                "service": service,
                "api_version": api_version,
                "feature": item,
            }
        return {
            "ok": False,
            "service": service,
            "api_version": api_version,
            "error": "unknown_feature",
            "feature": feature,
        }
    return {
        "ok": False,
        "service": service,
        "api_version": api_version,
        "error": "unknown_op",
        "op": op,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--journal", required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--api-version", required=True, type=int)
    args = parser.parse_args()

    pid = os.getpid()
    listen_pid = int(os.environ.get("LISTEN_PID", "0"))
    listen_fds = int(os.environ.get("LISTEN_FDS", "0"))
    if listen_pid != pid or listen_fds < 1:
        raise SystemExit(f"invalid socket activation env LISTEN_PID={listen_pid} LISTEN_FDS={listen_fds} pid={pid}")

    catalog = json.loads(pathlib.Path(args.catalog).read_text())
    conn = socket.fromfd(3, socket.AF_UNIX, socket.SOCK_STREAM)
    os.close(3)
    conn.settimeout(3.0)
    started = time.time()
    request = read_request(conn)
    response = response_for(request, catalog, args.service, args.api_version, args.journal)
    conn.sendall((json.dumps(response, sort_keys=True) + "\n").encode("utf-8"))
    conn.close()

    write_journal(
        args.journal,
        {
            "worker_pid": pid,
            "worker_start_ticks": pid_start_ticks(pid),
            "started_at": started,
            "operation": request.get("op"),
            "request": request,
            "response": response,
            "ok": bool(response.get("ok")),
        },
    )


if __name__ == "__main__":
    main()
