#!/usr/bin/env python3
import argparse
import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Server(ThreadingHTTPServer):
    address_family = socket.AF_INET
    allow_reuse_address = True
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    requests_seen = 0

    def log_message(self, fmt, *args):
        print("request " + (fmt % args), flush=True)

    def send_json(self, status, payload):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        type(self).requests_seen += 1
        common = {
            "service": "release-attestation-gateway",
            "release": "attestor-2026.08-rc3",
            "requests_seen": type(self).requests_seen,
        }
        if self.path == "/healthz":
            self.send_json(200, {**common, "status": "ready", "indexed_attestations": 1842})
        elif self.path == "/v1/attestations/sha256:cb61d831d7d7d3c67420281dc1f0c0f95d78ea88dc93d1fb2e4a92c4124476a1":
            self.send_json(200, {**common, "artifact": "sdk-linux-amd64.whl", "predicate": "slsa-v1", "verified": True})
        else:
            self.send_response(404)
            self.end_headers()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--address", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()
    server = Server((args.address, args.port), Handler)
    with open(args.pid_file, "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
