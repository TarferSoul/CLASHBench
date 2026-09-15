#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import signal
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


class Handler(BaseHTTPRequestHandler):
    server_version = "FeatureStoreWorker/4.0"

    def log_message(self, fmt, *args):
        print("feature-store " + (fmt % args), flush=True)

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        state = pathlib.Path(self.server.state)
        if self.path == "/healthz":
            self.send_json(200, {"service": self.server.service, "status": "ready", "workspace": "online-ranking", "identity": state.joinpath("identity").read_text().strip(), "worker_generation": int(state.joinpath("worker_generation").read_text())})
        elif urlparse(self.path).path == "/v1/features":
            count = int(state.joinpath("activity").read_text()) + 1
            state.joinpath("activity").write_text(f"{count}\n")
            self.send_json(200, {"service": self.server.service, "features": ["user-1042", "item-883"], "schema_revision": "feature-schema-2026.08", "worker_generation": int(state.joinpath("worker_generation").read_text())})
        else:
            self.send_json(404, {"service": self.server.service, "error": "not_found"})


class BoundServer(ThreadingHTTPServer):
    allow_reuse_address = False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fd", required=True, type=int)
    ap.add_argument("--port", required=True, type=int)
    ap.add_argument("--state", required=True)
    ap.add_argument("--service", required=True)
    args = ap.parse_args()
    sock = socket.fromfd(args.fd, socket.AF_INET, socket.SOCK_STREAM)
    server = BoundServer(("127.0.0.1", args.port), Handler, bind_and_activate=False)
    server.socket = sock
    server.server_address = ("127.0.0.1", args.port)
    server.state = args.state
    server.service = args.service
    listener_inode = os.readlink(f"/proc/{os.getpid()}/fd/{server.socket.fileno()}").split("[")[-1].rstrip("]")
    pathlib.Path(args.state, "worker_listener_inode").write_text(f"{listener_inode}\n")
    signal.signal(signal.SIGTERM, lambda _signum, _frame: (_ for _ in ()).throw(KeyboardInterrupt))
    signal.signal(signal.SIGINT, lambda _signum, _frame: (_ for _ in ()).throw(KeyboardInterrupt))
    print(f"feature-worker ready pid={os.getpid()} generation={pathlib.Path(args.state, 'worker_generation').read_text().strip()}", flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        pathlib.Path(args.state, "worker_listener_inode").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
