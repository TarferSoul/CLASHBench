#!/usr/bin/env python3
import argparse
import json
import pathlib
import socket
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name, dir=str(path.parent))
    with open(fd, "w") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
    pathlib.Path(tmp_name).replace(path)


class LinkGate:
    def __init__(self, rate, queue_limit, stats_path):
        self.rate = float(rate)
        self.queue_limit = int(queue_limit)
        self.stats_path = pathlib.Path(stats_path)
        self.lock = threading.Lock()
        self.next_free = time.monotonic()
        self.started_at = time.time()
        self.service_bytes = 0
        self.accepted_bytes = 0
        self.request_count = 0
        self.max_queue_bytes = 0
        self.max_sojourn_ms = 0.0
        self.last_write = 0.0
        self.write_stats(force=True)

    def current_queue_locked(self, now):
        return max(0.0, self.next_free - now) * self.rate

    def reserve(self, byte_count):
        if byte_count <= 0:
            return
        while True:
            with self.lock:
                now = time.monotonic()
                queued = self.current_queue_locked(now)
                if queued + byte_count <= self.queue_limit:
                    start_at = max(now, self.next_free)
                    sojourn = max(0.0, start_at - now)
                    self.next_free = start_at + byte_count / self.rate
                    self.accepted_bytes += byte_count
                    self.service_bytes += byte_count
                    self.max_queue_bytes = max(self.max_queue_bytes, int(queued + byte_count))
                    self.max_sojourn_ms = max(self.max_sojourn_ms, sojourn * 1000.0)
                    self.write_stats_locked(now, queued + byte_count)
                    break
                wait = min(max((queued + byte_count - self.queue_limit) / self.rate, 0.001), 0.05)
            time.sleep(wait)
        if sojourn > 0:
            time.sleep(sojourn)

    def mark_request(self):
        with self.lock:
            self.request_count += 1
            self.write_stats_locked(time.monotonic(), self.current_queue_locked(time.monotonic()))

    def snapshot_locked(self, now, queued):
        return {
            "started_at": self.started_at,
            "updated_at": time.time(),
            "rate_bytes_per_second": int(self.rate),
            "queue_limit_bytes": self.queue_limit,
            "queued_bytes": int(max(0.0, queued)),
            "service_bytes": int(self.service_bytes),
            "accepted_bytes": int(self.accepted_bytes),
            "request_count": int(self.request_count),
            "max_queued_bytes": int(self.max_queue_bytes),
            "max_sojourn_ms": float(self.max_sojourn_ms),
            "next_free_monotonic": float(self.next_free),
            "now_monotonic": float(now),
        }

    def write_stats_locked(self, now, queued):
        if now - self.last_write < 0.05:
            return
        atomic_json(self.stats_path, self.snapshot_locked(now, queued))
        self.last_write = now

    def write_stats(self, force=False):
        with self.lock:
            now = time.monotonic()
            if force:
                atomic_json(self.stats_path, self.snapshot_locked(now, self.current_queue_locked(now)))
                self.last_write = now
            else:
                self.write_stats_locked(now, self.current_queue_locked(now))


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *values):
        return

    @property
    def gate(self):
        return self.server.link_gate

    def do_HEAD(self):
        self.forward()

    def do_GET(self):
        self.forward()

    def do_POST(self):
        self.forward()

    def forward(self):
        self.close_connection = True
        self.gate.mark_request()
        try:
            with socket.create_connection(
                (self.server.backend_host, self.server.backend_port), timeout=10
            ) as backend:
                backend.settimeout(20)
                self.send_request_to_backend(backend)
                response = self.read_backend_response(backend)
                self.connection.sendall(response)
        except Exception as exc:
            body = json.dumps({"ok": False, "error": f"relay failure: {type(exc).__name__}"}).encode() + b"\n"
            try:
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
            except Exception:
                pass

    def send_through_link(self, backend, data):
        if not data:
            return
        self.gate.reserve(len(data))
        backend.sendall(data)

    def send_request_to_backend(self, backend):
        request_line = f"{self.command} {self.path} HTTP/1.1\r\n"
        headers = []
        hop_by_hop = {
            "connection",
            "keep-alive",
            "proxy-authenticate",
            "proxy-authorization",
            "proxy-connection",
            "te",
            "trailers",
            "transfer-encoding",
            "upgrade",
            "x-link-token",
        }
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in hop_by_hop:
                continue
            if lower == "host":
                continue
            headers.append(f"{key}: {value}\r\n")
        headers.append(f"Host: {self.server.backend_host}:{self.server.backend_port}\r\n")
        headers.append(f"X-Link-Token: {self.server.link_token}\r\n")
        headers.append("Connection: close\r\n")
        raw_headers = (request_line + "".join(headers) + "\r\n").encode()
        self.send_through_link(backend, raw_headers)

        remaining = int(self.headers.get("Content-Length", "0"))
        while remaining > 0:
            chunk = self.rfile.read(min(self.server.chunk_bytes, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
            self.send_through_link(backend, chunk)

    def read_backend_response(self, backend):
        chunks = []
        while True:
            data = backend.recv(65536)
            if not data:
                break
            chunks.append(data)
        return b"".join(chunks)


def stats_writer(gate, stop_event):
    while not stop_event.is_set():
        gate.write_stats()
        stop_event.wait(0.1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", required=True)
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--backend-host", required=True)
    parser.add_argument("--backend-port", type=int, required=True)
    parser.add_argument("--rate-bytes-per-second", type=int, required=True)
    parser.add_argument("--queue-limit-bytes", type=int, required=True)
    parser.add_argument("--chunk-bytes", type=int, required=True)
    parser.add_argument("--link-token", required=True)
    parser.add_argument("--stats-path", required=True)
    args = parser.parse_args()

    gate = LinkGate(args.rate_bytes_per_second, args.queue_limit_bytes, args.stats_path)
    server = ThreadingHTTPServer((args.listen_host, args.listen_port), ProxyHandler)
    server.backend_host = args.backend_host
    server.backend_port = args.backend_port
    server.link_token = args.link_token
    server.chunk_bytes = args.chunk_bytes
    server.link_gate = gate

    stop_event = threading.Event()
    thread = threading.Thread(target=stats_writer, args=(gate, stop_event), daemon=True)
    thread.start()
    try:
        server.serve_forever()
    finally:
        stop_event.set()
        gate.write_stats(force=True)


if __name__ == "__main__":
    main()

