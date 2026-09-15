#!/usr/bin/env python3
import argparse
import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class DualStackServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()
        self.v6only = self.socket.getsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY)


class Handler(BaseHTTPRequestHandler):
    requests_seen = 0

    def log_message(self, fmt, *args):
        print("request " + (fmt % args), flush=True)

    def send_json(self, payload):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        type(self).requests_seen += 1
        common = {
            "service": "model-route-catalog",
            "release": "routing-2026.08",
            "v6only": self.server.v6only,
            "requests_seen": type(self).requests_seen,
        }
        if self.path == "/healthz":
            self.send_json({**common, "status": "ready", "route_count": 2})
        elif self.path == "/v1/routes":
            self.send_json({
                **common,
                "generation": 73,
                "routes": [
                    {"name": "embed-v4", "backend": "encoder-blue"},
                    {"name": "rerank-v2", "backend": "reranker-green"},
                ],
            })
        else:
            self.send_response(404)
            self.end_headers()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()
    server = DualStackServer(("::", args.port), Handler)
    if server.v6only != 0:
        raise SystemExit("IPV6_V6ONLY was not disabled")
    with open(args.pid_file, "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
