#!/usr/bin/env python3
import http.server
import json
import os
import signal
import socket
import sys
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs, urlparse

host, port, worker, run_dir = sys.argv[1], int(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
pid = os.getpid()
stop_event = threading.Event()
request_count = 0
request_lock = threading.Lock()

def atomic_write(name, value):
    tmp = run_dir / (name + ".tmp")
    tmp.write_text(value, encoding="ascii")
    tmp.replace(run_dir / name)

def heartbeat():
    while not stop_event.is_set():
        atomic_write(f"worker_{worker}.heartbeat", f"{time.time():.6f}\n")
        stop_event.wait(0.2)

class ReuseServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = True
    def server_bind(self):
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()
        self.server_name = socket.getfqdn(self.server_address[0])
        self.server_port = self.server_address[1]

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def do_GET(self):
        global request_count
        with request_lock:
            request_count += 1
            count = request_count
            atomic_write(f"worker_{worker}.requests", f"{count}\n")
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            payload = {"ok": True, "service": "telemetry-schema-registry", "worker": worker}
        elif parsed.path == "/v1/schema":
            event = parse_qs(parsed.query).get("event", [""])[0]
            schemas = {
                "build.started": ["run_id", "commit", "started_at"],
                "build.finished": ["run_id", "status", "duration_ms"],
            }
            payload = {"ok": event in schemas, "service": "telemetry-schema-registry", "event": event, "fields": schemas.get(event, [])}
        elif parsed.path == "/metrics":
            payload = {"service": "telemetry-schema-registry", "worker": worker, "requests": count}
        else:
            self.send_error(404); return
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *_args):
        return

server = ReuseServer((host, port), Handler)
link = os.readlink(f"/proc/self/fd/{server.fileno()}")
atomic_write(f"worker_{worker}.pid", f"{pid}\n")
atomic_write(f"worker_{worker}.starttime", Path(f"/proc/{pid}/stat").read_text().split()[21] + "\n")
atomic_write(f"worker_{worker}.socket_inode", link[8:-1] + "\n")
atomic_write(f"worker_{worker}.requests", "0\n")
atomic_write(f"worker_{worker}.heartbeat", f"{time.time():.6f}\n")
threading.Thread(target=heartbeat, daemon=True).start()
atomic_write(f"worker_{worker}.ready", "ready\n")

def stop(_signum, _frame):
    stop_event.set(); os._exit(0)
signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
server.serve_forever(poll_interval=0.1)
