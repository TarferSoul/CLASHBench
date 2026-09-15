#!/usr/bin/env python3
import argparse
import errno
import json
import os
import pathlib
import signal
import socket
import sys
import time


FEATURE = {
    "name": os.environ.get("B_FEATURE_KEY", "embedding.text.similarity_v3"),
    "version": os.environ.get("B_FEATURE_VERSION", "2026.07.18"),
    "owner": os.environ.get("B_FEATURE_OWNER", "ml-platform"),
    "dimension": int(os.environ.get("B_FEATURE_DIMENSION", "1024")),
    "dtype": os.environ.get("B_FEATURE_DTYPE", "float32"),
    "index": os.environ.get("B_FEATURE_INDEX", "ann-text-prod-v3"),
    "digest": os.environ.get("B_FEATURE_DIGEST", "sha256:54db763d8deca1af8e8ab93e4ed7f61da8c36fe45d540d7fb1472a46ec4c2e0c"),
}


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


def response_for(request, service, api_version):
    op = request.get("op")
    if op == "health":
        return {
            "ok": True,
            "service": service,
            "api_version": api_version,
            "catalog_entries": 2,
        }
    if op == "describe":
        if request.get("feature") == FEATURE["name"]:
            return {
                "ok": True,
                "service": service,
                "api_version": api_version,
                "feature": FEATURE,
            }
        return {
            "ok": False,
            "service": service,
            "api_version": api_version,
            "error": "unknown_feature",
            "feature": request.get("feature"),
        }
    return {
        "ok": False,
        "service": service,
        "api_version": api_version,
        "error": "unknown_op",
        "op": op,
    }


def write_journal(path, record):
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--ready", required=True)
    parser.add_argument("--journal", required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--api-version", required=True, type=int)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    socket_path = pathlib.Path(args.socket)
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    bound = False
    stopping = False

    def handle_signal(signum, frame):
        nonlocal stopping
        stopping = True
        try:
            listener.close()
        except OSError:
            pass

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    try:
        listener.bind(str(socket_path))
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            print("B_BIND_ERROR=EADDRINUSE errno=98", flush=True)
            raise SystemExit(98)
        raise
    bound = True
    listener.listen(8)
    os.chmod(socket_path, 0o666)
    ready = {
        "service": args.service,
        "api_version": args.api_version,
        "socket": str(socket_path),
        "pid": os.getpid(),
        "pid_start_ticks": pid_start_ticks(os.getpid()),
    }
    pathlib.Path(args.ready).write_text(json.dumps(ready, sort_keys=True) + "\n")

    served = 0
    while not stopping:
        try:
            conn, _ = listener.accept()
        except OSError:
            if stopping:
                break
            raise
        with conn:
            conn.settimeout(3.0)
            request = read_request(conn)
            response = response_for(request, args.service, args.api_version)
            conn.sendall((json.dumps(response, sort_keys=True) + "\n").encode("utf-8"))
        served += 1
        write_journal(
            args.journal,
            {
                "server_pid": os.getpid(),
                "operation": request.get("op"),
                "request": request,
                "response": response,
                "ok": bool(response.get("ok")),
            },
        )
        if args.once and served >= 1:
            break

    listener.close()
    if bound:
        try:
            socket_path.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    main()
