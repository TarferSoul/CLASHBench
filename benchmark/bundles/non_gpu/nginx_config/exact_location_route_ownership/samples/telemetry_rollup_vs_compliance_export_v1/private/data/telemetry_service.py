#!/usr/bin/env python3
import argparse, csv, json, os, signal, tempfile, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser(description="Serve an internal telemetry summary")
parser.add_argument("--port", required=True, type=int)
parser.add_argument("--service", required=True)
parser.add_argument("--snapshot", required=True)
parser.add_argument("--endpoint", required=True)
parser.add_argument("--data", required=True)
parser.add_argument("--state-file", required=True)
args = parser.parse_args()
lock = threading.Lock()
started = time.time()
counters = {"request_count": 0, "health_count": 0, "last_path": "startup"}

def summary():
    total = warnings = 0
    with open(args.data, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            total += 1
            warnings += row.get("severity") in {"warning", "critical"}
    return total, warnings

def save_state():
    os.makedirs(os.path.dirname(args.state_file), exist_ok=True)
    payload = {"pid": os.getpid(), "service": args.service, "snapshot": args.snapshot,
               "started_at": started, "heartbeat_epoch": time.time(), **counters}
    fd, tmp = tempfile.mkstemp(prefix=".state-", dir=os.path.dirname(args.state_file), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True); handle.write("\n")
        os.replace(tmp, args.state_file)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            with lock:
                counters["health_count"] += 1; counters["last_path"] = self.path; save_state()
            payload = {"service": args.service, "status": "ready"}
        elif self.path == args.endpoint:
            total, warnings = summary()
            with lock:
                counters["request_count"] += 1; counters["last_path"] = self.path; save_state()
            payload = {"service": args.service, "status": "ready", "snapshot": args.snapshot,
                       "event_count": total, "warning_count": warnings}
        else:
            self.send_error(404); return
        encoded = json.dumps(payload, sort_keys=True).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("X-Telemetry-Service", args.service)
        self.end_headers(); self.wfile.write(encoded)
    def log_message(self, fmt, *values):
        print(fmt % values, flush=True)

class Server(ThreadingHTTPServer):
    allow_reuse_address = True

save_state()
server = Server(("127.0.0.1", args.port), Handler)
signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
signal.signal(signal.SIGINT, lambda *_: threading.Thread(target=server.shutdown).start())
server.serve_forever(poll_interval=0.1)
