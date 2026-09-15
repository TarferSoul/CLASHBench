#!/usr/bin/env python3
import argparse
import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class IPv4Server(ThreadingHTTPServer):
    address_family = socket.AF_INET
    allow_reuse_address = True
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("request " + (fmt % args), flush=True)

    def do_GET(self):
        if self.path == "/ready":
            body = json.dumps({
                "service": "legacy-metrics-bridge",
                "status": "ready",
                "release": "collector-2026.08",
                "address_family": "ipv4",
            }, sort_keys=True).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
        elif self.path == "/metrics":
            body = (
                "# HELP legacy_queue_depth Pending records in the compatibility queue.\n"
                "# TYPE legacy_queue_depth gauge\n"
                "legacy_queue_depth{pipeline=\"embedding-index\"} 7\n"
                "# HELP legacy_bridge_info Compatibility bridge release marker.\n"
                "# TYPE legacy_bridge_info gauge\n"
                "legacy_bridge_info{version=\"2026.08\"} 1\n"
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--address", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()
    try:
        server = IPv4Server((args.address, args.port), Handler)
    except OSError as exc:
        print(f"BIND_ERROR errno={exc.errno} address={args.address} port={args.port} message={exc}", flush=True)
        raise SystemExit(exc.errno if exc.errno and exc.errno < 126 else 1)
    with open(args.pid_file, "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
