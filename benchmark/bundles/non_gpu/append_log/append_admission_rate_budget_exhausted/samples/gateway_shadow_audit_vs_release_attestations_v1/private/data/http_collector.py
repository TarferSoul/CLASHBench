#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import socket
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class State:
    def __init__(self, args):
        self.args = args
        self.secret = pathlib.Path(args.token_file).read_text().strip()
        self.lock = threading.RLock()
        self.log_path = pathlib.Path(args.append_log)
        self.state_path = pathlib.Path(args.state)
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_path.touch(exist_ok=True)
        self.handle = self.log_path.open("ab", buffering=0)
        self.sequence = self._next_sequence()
        self.started_at = utc_now()
        self.started_monotonic = time.monotonic()
        self.tokens = float(args.burst_tokens)
        self.last_refill = time.monotonic()
        self.admitted = {}
        self.throttled = {}
        self.dropped = {}
        self.protocol_errors = 0
        self.fsync_count = 0
        self.fsync_ms_max = 0.0
        self.fsync_samples = []
        self.last_event_id = ""
        self._persist_locked()

    def _next_sequence(self):
        highest = -1
        for line in self.log_path.read_text(errors="replace").splitlines():
            try:
                highest = max(highest, int(json.loads(line).get("sequence", -1)))
            except Exception:
                continue
        return highest + 1

    def _refill_locked(self):
        now = time.monotonic()
        elapsed = max(0.0, now - self.last_refill)
        self.tokens = min(
            float(self.args.burst_tokens),
            self.tokens + elapsed * float(self.args.refill_per_second),
        )
        self.last_refill = now

    def _log_identity(self):
        item = self.log_path.stat()
        return item.st_dev, item.st_ino, item.st_size

    def _persist_locked(self):
        self._refill_locked()
        device, inode, size = self._log_identity()
        payload = {
            "status": "OK",
            "protocol": "http-json-event-append",
            "pid": os.getpid(),
            "started_at": self.started_at,
            "uptime_seconds": round(time.monotonic() - self.started_monotonic, 3),
            "endpoint": f"http://{self.args.host}:{self.args.port}",
            "append_log_device": device,
            "append_log_inode": inode,
            "append_log_size": size,
            "token_bucket": {
                "refill_events_per_second": self.args.refill_per_second,
                "burst_tokens": self.args.burst_tokens,
                "available_tokens": round(self.tokens, 3),
            },
            "admitted_by_owner": dict(sorted(self.admitted.items())),
            "throttled_by_owner": dict(sorted(self.throttled.items())),
            "dropped_by_owner": dict(sorted(self.dropped.items())),
            "total_admitted": sum(self.admitted.values()),
            "total_throttled": sum(self.throttled.values()),
            "total_dropped": sum(self.dropped.values()),
            "protocol_errors": self.protocol_errors,
            "fsync_count": self.fsync_count,
            "fsync_ms_max": round(self.fsync_ms_max, 3),
            "fsync_ms_mean": round(sum(self.fsync_samples) / len(self.fsync_samples), 3) if self.fsync_samples else 0.0,
            "fsync_ms_p95": round(sorted(self.fsync_samples)[max(0, int(len(self.fsync_samples) * 0.95) - 1)], 3) if self.fsync_samples else 0.0,
            "next_sequence": self.sequence,
            "last_event_id": self.last_event_id,
            "updated_at": utc_now(),
        }
        tmp = self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
        os.chmod(tmp, 0o600)
        tmp.replace(self.state_path)
        return payload

    def snapshot(self):
        with self.lock:
            return self._persist_locked()

    def protocol_error(self):
        with self.lock:
            self.protocol_errors += 1
            self._persist_locked()

    def append(self, request):
        owner = str(request.get("owner") or "unknown")
        event_id = str(request.get("event_id") or "")
        with self.lock:
            self._refill_locked()
            if self.tokens < 1.0:
                self.throttled[owner] = self.throttled.get(owner, 0) + 1
                self.dropped[owner] = self.dropped.get(owner, 0) + 1
                self._persist_locked()
                return HTTPStatus.TOO_MANY_REQUESTS, {
                    "status": "THROTTLED",
                    "event_id": event_id,
                    "retry_after_ms": self.args.retry_after_ms,
                    "available_tokens": round(self.tokens, 3),
                }
            self.tokens -= 1.0
            frame = {
                "record_type": "DURABLE_APPEND_EVENT",
                "sequence": self.sequence,
                "owner": owner,
                "client_id": str(request.get("client_id") or ""),
                "transaction": str(request.get("transaction") or ""),
                "stream": str(request.get("stream") or ""),
                "event_id": event_id,
                "event_type": str(request.get("event_type") or ""),
                "payload": request.get("payload") or {},
                "received_at": utc_now(),
            }
            frame["payload_sha256"] = hashlib.sha256(
                canonical(frame["payload"]).encode()
            ).hexdigest()
            raw = (canonical(frame) + "\n").encode()
            offset = self.handle.tell()
            self.handle.write(raw)
            before = time.perf_counter()
            os.fsync(self.handle.fileno())
            fsync_ms = (time.perf_counter() - before) * 1000.0
            durable_offset = offset + len(raw)
            device, inode, _ = self._log_identity()
            self.sequence += 1
            self.fsync_count += 1
            self.fsync_ms_max = max(self.fsync_ms_max, fsync_ms)
            self.fsync_samples.append(fsync_ms)
            self.fsync_samples = self.fsync_samples[-512:]
            self.admitted[owner] = self.admitted.get(owner, 0) + 1
            self.last_event_id = event_id
            self._persist_locked()
            receipt = {
                "status": "ADMITTED",
                "event_id": event_id,
                "sequence": frame["sequence"],
                "offset": offset,
                "durable_offset": durable_offset,
                "append_log_device": device,
                "append_log_inode": inode,
                "payload_sha256": frame["payload_sha256"],
                "fsync_ms": round(fsync_ms, 3),
            }
            receipt["receipt_sha256"] = hashlib.sha256(canonical(receipt).encode()).hexdigest()
            return HTTPStatus.OK, receipt


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def log_message(self, _format, *_args):
        return

    def send_json(self, status, payload):
        raw = (json.dumps(payload, sort_keys=True) + "\n").encode()
        self.send_response(int(status))
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path in ("/health", "/stats"):
            self.send_json(HTTPStatus.OK, self.server.state.snapshot())
        else:
            self.send_json(HTTPStatus.NOT_FOUND, {"status": "NOT_FOUND"})

    def do_POST(self):
        if self.path != "/append":
            self.send_json(HTTPStatus.NOT_FOUND, {"status": "NOT_FOUND"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            request = json.loads(self.rfile.read(length).decode())
        except Exception as exc:
            self.server.state.protocol_error()
            self.send_json(HTTPStatus.BAD_REQUEST, {"status": "BAD_REQUEST", "error": type(exc).__name__})
            return
        supplied = self.headers.get("Authorization", "")
        if supplied.startswith("Bearer "):
            supplied = supplied.split(" ", 1)[1]
        if supplied != self.server.state.secret:
            self.server.state.protocol_error()
            self.send_json(HTTPStatus.UNAUTHORIZED, {"status": "AUTH_FAILED"})
            return
        if not request.get("owner") or not request.get("event_id"):
            self.server.state.protocol_error()
            self.send_json(HTTPStatus.BAD_REQUEST, {"status": "BAD_REQUEST"})
            return
        status, response = self.server.state.append(request)
        self.send_json(status, response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--append-log", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--refill-per-second", required=True, type=float)
    parser.add_argument("--burst-tokens", required=True, type=float)
    parser.add_argument("--retry-after-ms", type=int, default=12)
    args = parser.parse_args()
    state = State(args)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.state = state

    def stop(_signum, _frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(
        f"COLLECTOR_READY pid={os.getpid()} endpoint=http://{args.host}:{args.port} "
        f"refill_eps={args.refill_per_second} burst={args.burst_tokens}",
        flush=True,
    )
    server.serve_forever(poll_interval=0.1)
    state.handle.close()
    server.server_close()


if __name__ == "__main__":
    main()
