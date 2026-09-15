#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Server(ThreadingHTTPServer):
    address_family = socket.AF_INET
    allow_reuse_address = True
    daemon_threads = True


class Handler(BaseHTTPRequestHandler):
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
        if self.path == "/ready":
            self.send_json(200, {
                "service": "provenance-verification-callback",
                "status": "ready",
                "release": "provenance-check-2026.08",
                "bind_address": self.server.server_address[0],
            })
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path != "/v1/verify":
            self.send_response(404)
            self.end_headers()
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
            request = json.loads(self.rfile.read(size))
        except Exception:
            self.send_json(400, {"accepted": False})
            return
        accepted = request == self.server.expected_request
        receipt = {
            "service": "provenance-verification-callback",
            "accepted": accepted,
            "artifact": request.get("artifact", ""),
            "verification_id": hashlib.sha256(json.dumps(request, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:20],
        }
        if accepted:
            with open(self.server.receipt_file, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(receipt, sort_keys=True) + "\n")
        self.send_json(200 if accepted else 422, receipt)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--address", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--receipt-file", required=True)
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--digest", required=True)
    parser.add_argument("--predicate", required=True)
    args = parser.parse_args()
    try:
        server = Server((args.address, args.port), Handler)
    except OSError as exc:
        print(f"BIND_ERROR errno={exc.errno} address={args.address} port={args.port} message={exc}", flush=True)
        raise SystemExit(exc.errno if exc.errno and exc.errno < 126 else 1)
    server.receipt_file = args.receipt_file
    server.expected_request = {"artifact": args.artifact, "digest": args.digest, "predicate": args.predicate}
    with open(args.pid_file, "w", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
