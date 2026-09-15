#!/usr/bin/env python3
"""Directional, shared-rate TCP gateway for an isolated outbound lane."""
import argparse
import json
import os
import signal
import socket
import socketserver
import threading
import time
from pathlib import Path


def atomic_json(path: Path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


class Lane:
    def __init__(self, rate, stats_path, events_path):
        self.rate = float(rate)
        self.stats_path = Path(stats_path)
        self.events_path = Path(events_path)
        self.lock = threading.Lock()
        self.next_free = time.monotonic()
        now = time.time()
        self.stats = {
            "mode": "root_configured_directional_userspace_gateway",
            "rate_bytes_per_second": int(rate),
            "started_at": now,
            "first_incumbent_service_at": None,
            "service_bytes": 0,
            "incumbent_service_bytes": 0,
            "task_service_bytes": 0,
            "control_service_bytes": 0,
            "downstream_bytes": 0,
            "queued_bytes": 0,
            "max_queued_bytes": 0,
            "active_connections": 0,
            "max_active_connections": 0,
            "completed_connections": 0,
            "last_update": now,
        }
        atomic_json(self.stats_path, self.stats)

    def connection(self, delta):
        with self.lock:
            self.stats["active_connections"] += delta
            self.stats["max_active_connections"] = max(
                self.stats["max_active_connections"], self.stats["active_connections"]
            )
            if delta < 0:
                self.stats["completed_connections"] += 1
            self.stats["last_update"] = time.time()
            atomic_json(self.stats_path, self.stats)

    def reserve(self, amount, stream):
        with self.lock:
            now = time.monotonic()
            start = max(now, self.next_free)
            finish = start + amount / self.rate
            self.next_free = finish
            queued = int(max(0.0, finish - now) * self.rate)
            self.stats["queued_bytes"] = queued
            self.stats["max_queued_bytes"] = max(self.stats["max_queued_bytes"], queued)
            self.stats["last_update"] = time.time()
            atomic_json(self.stats_path, self.stats)
        delay = max(0.0, finish - time.monotonic())
        if delay:
            time.sleep(delay)

    def committed(self, amount, stream, name):
        with self.lock:
            now = time.monotonic()
            self.stats["service_bytes"] += amount
            key = f"{stream}_service_bytes" if stream in {"incumbent", "task", "control"} else "control_service_bytes"
            self.stats[key] += amount
            if stream == "incumbent" and self.stats["first_incumbent_service_at"] is None:
                self.stats["first_incumbent_service_at"] = time.time()
            self.stats["queued_bytes"] = int(max(0.0, self.next_free - now) * self.rate)
            self.stats["last_update"] = time.time()
            atomic_json(self.stats_path, self.stats)
            with self.events_path.open("a") as handle:
                handle.write(json.dumps({"at": time.time(), "stream": stream, "name": name, "bytes": amount}) + "\n")

    def downstream(self, amount):
        with self.lock:
            self.stats["downstream_bytes"] += amount
            self.stats["last_update"] = time.time()
            atomic_json(self.stats_path, self.stats)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        lane = self.server.lane
        lane.connection(1)
        try:
            with socket.create_connection(self.server.backend, timeout=4.0) as backend:
                self.request.settimeout(12.0)
                backend.settimeout(12.0)
                header_buffer = b""
                while b"\n" not in header_buffer and len(header_buffer) < 16384:
                    piece = self.request.recv(4096)
                    if not piece:
                        return
                    header_buffer += piece
                header_line, payload_buffer = header_buffer.split(b"\n", 1)
                spec = json.loads(header_line.decode())
                expected = int(spec.get("size", 0))
                if expected < 0 or expected > 4_000_000:
                    raise ValueError("invalid payload size")
                stream = str(spec.get("stream", "control"))
                name = str(spec.get("name", "unnamed"))
                framed_header = header_line + b"\n"
                lane.reserve(len(framed_header), stream)
                backend.sendall(framed_header)
                lane.committed(len(framed_header), stream, name)
                received = 0
                pending = payload_buffer[:expected]
                while received < expected:
                    if not pending:
                        pending = self.request.recv(min(32768, expected - received))
                        if not pending:
                            raise ConnectionError("short upstream payload")
                    piece = pending[: min(16384, expected - received)]
                    pending = pending[len(piece) :]
                    lane.reserve(len(piece), stream)
                    backend.sendall(piece)
                    lane.committed(len(piece), stream, name)
                    received += len(piece)
                backend.shutdown(socket.SHUT_WR)
                while True:
                    piece = backend.recv(65536)
                    if not piece:
                        break
                    self.request.sendall(piece)
                    lane.downstream(len(piece))
        finally:
            lane.connection(-1)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", required=True)
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--backend-host", required=True)
    parser.add_argument("--backend-port", type=int, required=True)
    parser.add_argument("--rate-bytes-per-second", type=int, required=True)
    parser.add_argument("--stats", required=True)
    parser.add_argument("--events", required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()
    Path(args.pid_file).write_text(str(os.getpid()) + "\n")
    os.chmod(args.pid_file, 0o600)
    lane = Lane(args.rate_bytes_per_second, args.stats, args.events)
    with Server((args.listen_host, args.listen_port), Handler) as server:
        server.backend = (args.backend_host, args.backend_port)
        server.lane = lane

        def stop(_signal, _frame):
            threading.Thread(target=server.shutdown, daemon=True).start()

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        server.serve_forever(poll_interval=0.1)


if __name__ == "__main__":
    main()

