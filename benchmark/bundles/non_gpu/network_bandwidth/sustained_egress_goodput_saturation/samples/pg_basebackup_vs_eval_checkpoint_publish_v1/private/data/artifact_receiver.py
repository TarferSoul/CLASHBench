#!/usr/bin/env python3
"""Checksum-verifying receiver for engineering artifacts and reverse controls."""
import argparse
import hashlib
import json
import os
import signal
import socketserver
import threading
import time
from pathlib import Path


def deterministic_bytes(label, size):
    output = bytearray()
    counter = 0
    while len(output) < size:
        output.extend(hashlib.sha256(f"{label}:{counter}".encode()).digest())
        counter += 1
    return bytes(output[:size])


class State:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.commits = self.root / "commits.jsonl"
        self.health = self.root / "receiver_health.json"
        self.lock = threading.Lock()
        self.values = {"status": "ok", "commits": 0, "committed_bytes": 0, "reverse_controls": 0, "errors": 0, "updated_at": time.time()}
        self.write_health()

    def write_health(self):
        temporary = self.health.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.values, sort_keys=True) + "\n")
        os.chmod(temporary, 0o600)
        temporary.replace(self.health)

    def commit(self, value):
        with self.lock:
            with self.commits.open("a") as handle:
                handle.write(json.dumps(value, sort_keys=True) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
            self.values["commits"] += 1
            self.values["committed_bytes"] += int(value["size"])
            self.values["updated_at"] = time.time()
            self.write_health()

    def reverse(self):
        with self.lock:
            self.values["reverse_controls"] += 1
            self.values["updated_at"] = time.time()
            self.write_health()

    def error(self):
        with self.lock:
            self.values["errors"] += 1
            self.values["updated_at"] = time.time()
            self.write_health()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        state = self.server.state
        self.request.settimeout(12.0)
        try:
            header = b""
            while b"\n" not in header and len(header) < 16384:
                piece = self.request.recv(4096)
                if not piece:
                    return
                header += piece
            line, buffered = header.split(b"\n", 1)
            spec = json.loads(line.decode())
            if spec.get("kind") == "reverse-control":
                size = int(spec["response_bytes"])
                payload = deterministic_bytes(str(spec["name"]), size)
                digest = hashlib.sha256(payload).hexdigest()
                response = {"ok": True, "name": spec["name"], "size": size, "sha256": digest}
                self.request.sendall((json.dumps(response, sort_keys=True) + "\n").encode() + payload)
                state.reverse()
                return
            size = int(spec["size"])
            if size < 1 or size > 4_000_000:
                raise ValueError("invalid artifact size")
            digest = hashlib.sha256()
            initial = buffered[:size]
            digest.update(initial)
            received = len(initial)
            while received < size:
                piece = self.request.recv(min(65536, size - received))
                if not piece:
                    raise ConnectionError("short artifact")
                digest.update(piece)
                received += len(piece)
            processing_started = time.monotonic()
            actual = digest.hexdigest()
            if actual != spec["sha256"]:
                raise ValueError("digest mismatch")
            value = {
                "stream": str(spec.get("stream", "unknown")),
                "kind": str(spec.get("kind", "artifact")),
                "name": str(spec["name"]),
                "revision": str(spec.get("revision", "")),
                "size": size,
                "sha256": actual,
                "committed_at": time.time(),
                "processing_ms": round((time.monotonic() - processing_started) * 1000, 3),
            }
            state.commit(value)
            self.request.sendall((json.dumps({"committed": True, **value}, sort_keys=True) + "\n").encode())
        except Exception as exc:
            state.error()
            try:
                self.request.sendall((json.dumps({"committed": False, "error": type(exc).__name__}) + "\n").encode())
            except OSError:
                pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()
    Path(args.pid_file).write_text(str(os.getpid()) + "\n")
    os.chmod(args.pid_file, 0o600)
    state = State(args.state)
    with Server((args.host, args.port), Handler) as server:
        server.state = state

        def stop(_signal, _frame):
            threading.Thread(target=server.shutdown, daemon=True).start()

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        server.serve_forever(poll_interval=0.1)


if __name__ == "__main__":
    main()
