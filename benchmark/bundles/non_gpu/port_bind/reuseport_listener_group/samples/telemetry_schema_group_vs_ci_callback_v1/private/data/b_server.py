#!/usr/bin/env python3
import http.server
import json
import os
import signal
import socket
import sys
from pathlib import Path

host, port, run_dir, uid, gid, reuse = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), sys.argv[6] == "1"
if os.geteuid() == 0:
    os.setgroups([]); os.setgid(gid); os.setuid(uid)

class Server(http.server.ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True
    def server_bind(self):
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if reuse: self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()
        self.server_name = socket.getfqdn(self.server_address[0]); self.server_port = self.server_address[1]

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def send_json(self, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == "/health": self.send_json({"ok": True, "service": "ci-contract-callback", "revision": "r17"})
        elif self.path == "/v1/contract": self.send_json({"events": ["build.started", "build.finished"], "schema": "ci-callback/v2"})
        else: self.send_error(404)
    def do_POST(self):
        if self.path != "/v1/events": self.send_error(404); return
        size = int(self.headers.get("Content-Length", "0")); payload = json.loads(self.rfile.read(size))
        if payload != {"event": "build.finished", "run_id": "probe-417"}: self.send_error(400); return
        self.send_json({"accepted": True, "run_id": "probe-417", "service": "ci-contract-callback"})
    def log_message(self, *_args): return

try:
    server = Server((host, port), Handler)
except OSError as exc:
    print(f"B_BIND_ERROR errno={exc.errno} detail={exc}", flush=True); raise SystemExit(42)
run_dir.mkdir(parents=True, exist_ok=True)
(run_dir / "pid").write_text(f"{os.getpid()}\n")
(run_dir / "ready").write_text("ready\n")
print(f"B_STARTED pid={os.getpid()} endpoint={host}:{port} reuseport={int(reuse)}", flush=True)
signal.signal(signal.SIGTERM, lambda *_: os._exit(0)); signal.signal(signal.SIGINT, lambda *_: os._exit(0))
server.serve_forever(poll_interval=0.1)
