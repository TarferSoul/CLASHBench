#!/usr/bin/env python3
import argparse
import errno
import json
import os
import pathlib
import signal
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Server(ThreadingHTTPServer):
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    server_version = "EmbeddingEvalSink/1.0"

    def log_message(self, fmt, *args):
        print("embedding-eval " + (fmt % args), flush=True)

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/ready":
            self.send_json(200, {"service": self.server.service, "status": "ready", "release": self.server.release})
        else:
            self.send_json(404, {"service": self.server.service, "error": "not_found"})

    def do_POST(self):
        if self.path != "/v1/results":
            self.send_json(404, {"service": self.server.service, "error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length))
        except Exception:
            self.send_json(400, {"accepted": False})
            return
        expected = {"run_id": self.server.job_id, "shard": self.server.model, "score": self.server.accuracy, "count": self.server.latency_ms}
        if payload != expected:
            self.send_json(422, {"accepted": False})
            return
        receipt = {**payload, "accepted": True}
        with open(self.server.receipt, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")
        self.send_json(202, {"accepted": True, "run_id": self.server.job_id, "shard": self.server.model})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--address", required=True)
    ap.add_argument("--port", required=True, type=int)
    ap.add_argument("--pid-file", required=True)
    ap.add_argument("--ready-file", required=True)
    ap.add_argument("--receipt", required=True)
    ap.add_argument("--service", required=True)
    ap.add_argument("--release", required=True)
    ap.add_argument("--job-id", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--accuracy", required=True, type=float)
    ap.add_argument("--latency-ms", required=True, type=int)
    args = ap.parse_args()
    try:
        server = Server((args.address, args.port), Handler)
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            print(f"BIND_ERROR errno={exc.errno} address={args.address} port={args.port}", flush=True)
            return 98
        raise
    server.service, server.release = args.service, args.release
    server.job_id, server.model = args.job_id, args.model
    server.accuracy, server.latency_ms = args.accuracy, args.latency_ms
    server.receipt = args.receipt
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
    pathlib.Path(args.ready_file).write_text("ready\n")
    signal.signal(signal.SIGTERM, lambda _signum, _frame: (_ for _ in ()).throw(KeyboardInterrupt))
    signal.signal(signal.SIGINT, lambda _signum, _frame: (_ for _ in ()).throw(KeyboardInterrupt))
    print(f"embedding-eval-sink ready address={args.address} port={args.port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        pathlib.Path(args.pid_file).unlink(missing_ok=True)
        pathlib.Path(args.ready_file).unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
