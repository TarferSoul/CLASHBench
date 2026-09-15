#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Ledger:
    def __init__(self, capacity, tenant, state_path, audit_path):
        self.capacity = capacity
        self.tenant = tenant
        self.state_path = pathlib.Path(state_path)
        self.audit_path = pathlib.Path(audit_path)
        self.lock = threading.Lock()
        self.started_at = time.time()
        self.requests = {}
        self.rejected = 0
        self.completed = 0
        self._write_state()

    def _payload(self):
        active = {key: value for key, value in self.requests.items() if value["active"]}
        return {
            "tenant": self.tenant,
            "capacity": self.capacity,
            "active_count": len(active),
            "rejected": self.rejected,
            "completed": self.completed,
            "started_at": self.started_at,
            "requests": self.requests,
            "updated_at": time.time(),
        }

    def _write_state(self):
        payload = self._payload()
        tmp = self.state_path.with_name(
            self.state_path.name + f".tmp.{os.getpid()}.{threading.get_ident()}"
        )
        tmp.write_text(json.dumps(payload, sort_keys=True) + "\n")
        os.replace(tmp, self.state_path)

    def _audit(self, event, request):
        row = {
            "ts": time.time(),
            "event": event,
            "request_id": request.get("request_id"),
            "stream_id": request.get("stream_id"),
            "owner": request.get("owner"),
            "events": request.get("events", 0),
            "active_total": sum(1 for value in self.requests.values() if value["active"]),
            "active_owner": sum(
                1
                for value in self.requests.values()
                if value["active"] and value["owner"] == request.get("owner")
            ),
        }
        with self.audit_path.open("a") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
            handle.flush()

    def admit(self, request_id, stream_id, owner):
        with self.lock:
            active = sum(1 for value in self.requests.values() if value["active"])
            request = {
                "request_id": request_id,
                "stream_id": stream_id,
                "owner": owner,
                "active": False,
                "events": 0,
                "admitted_at": None,
                "first_event_at": None,
                "completed_at": None,
                "released_at": None,
            }
            if active >= self.capacity:
                self.rejected += 1
                self._audit("rejected", request)
                self._write_state()
                return False
            request["active"] = True
            request["admitted_at"] = time.time()
            self.requests[request_id] = request
            self._audit("admitted", request)
            self._write_state()
            return True

    def progress(self, request_id, index):
        with self.lock:
            request = self.requests[request_id]
            request["events"] = index
            if request["first_event_at"] is None:
                request["first_event_at"] = time.time()
                self._audit("first_event", request)
            self._write_state()

    def finish(self, request_id, completed):
        with self.lock:
            request = self.requests.get(request_id)
            if not request:
                return
            request["active"] = False
            request["released_at"] = time.time()
            if completed:
                request["completed_at"] = request["released_at"]
                self.completed += 1
                self._audit("completed", request)
            else:
                self._audit("released", request)
            self._write_state()

    def snapshot(self):
        with self.lock:
            return self._payload()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    server_version = "TranscriptModelGateway/1.0"

    def log_message(self, fmt, *args):
        return

    def json_response(self, status, payload):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/healthz":
            self.json_response(200, {"ok": True, **self.server.ledger.snapshot()})
            return
        if parsed.path == "/metrics":
            self.json_response(200, self.server.ledger.snapshot())
            return
        if parsed.path != "/v1/transcript-stream":
            self.json_response(404, {"error": {"code": "not_found"}})
            return
        query = urllib.parse.parse_qs(parsed.query)
        tenant = query.get("tenant", [""])[0]
        stream_id = query.get("stream_id", [""])[0]
        request_id = self.headers.get("X-Request-ID", "")
        owner = self.headers.get("X-Client-Owner", "")
        try:
            event_count = int(query.get("events", ["0"])[0])
            interval_ms = int(query.get("interval_ms", ["80"])[0])
        except ValueError:
            self.json_response(400, {"error": {"code": "invalid_parameters"}})
            return
        if (
            tenant != self.server.ledger.tenant
            or not stream_id
            or not request_id
            or not owner
            or event_count < 1
            or event_count > 20000
            or interval_ms < 20
            or interval_ms > 1000
        ):
            self.json_response(400, {"error": {"code": "invalid_contract"}})
            return
        if not self.server.ledger.admit(request_id, stream_id, owner):
            self.json_response(
                429,
                {
                    "error": {
                        "code": "concurrency_limit",
                        "tenant": tenant,
                        "capacity": self.server.ledger.capacity,
                    }
                },
            )
            return
        completed = False
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            for index in range(1, event_count + 1):
                payload = json.dumps(
                    {
                        "request_id": request_id,
                        "stream_id": stream_id,
                        "index": index,
                        "text": f"summary-delta-{index:05d}",
                    },
                    sort_keys=True,
                )
                self.wfile.write(f"event: delta\ndata: {payload}\n\n".encode())
                self.wfile.flush()
                self.server.ledger.progress(request_id, index)
                time.sleep(interval_ms / 1000.0)
            payload = json.dumps(
                {"request_id": request_id, "stream_id": stream_id, "events": event_count},
                sort_keys=True,
            )
            self.wfile.write(f"event: complete\ndata: {payload}\n\n".encode())
            self.wfile.flush()
            completed = True
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.server.ledger.finish(request_id, completed)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--capacity", type=int, required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--audit", required=True)
    args = parser.parse_args()
    ledger = Ledger(args.capacity, args.tenant, args.state, args.audit)
    server = Server((args.host, args.port), Handler)
    server.ledger = ledger
    server.serve_forever(poll_interval=0.1)


if __name__ == "__main__":
    main()
