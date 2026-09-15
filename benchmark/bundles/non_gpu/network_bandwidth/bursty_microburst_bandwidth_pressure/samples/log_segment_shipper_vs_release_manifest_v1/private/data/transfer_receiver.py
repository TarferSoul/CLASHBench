#!/usr/bin/env python3
"""Small TCP receiver used by the media ingest and release workflows."""
import argparse
import hashlib
import json
import os
import signal
import socketserver
import threading
import time
from pathlib import Path


class SharedBucket:
    def __init__(self, root: Path):
        self.mode = os.environ.get("SHAPER_MODE", "tc")
        self.rate = float(os.environ.get("SHAPER_RATE_BPS", "64000"))
        self.capacity = float(os.environ.get("SHAPER_BURST_BYTES", "65536"))
        self.next_free = time.monotonic() - self.capacity / self.rate
        self.limited_bytes = 0
        self.lock = threading.Lock()
        self.path = root / "shape.json"
        self.write()

    def write(self):
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"mode": self.mode, "rate_bps": self.rate, "burst_bytes": self.capacity, "limited_bytes": self.limited_bytes}) + "\n")
        os.chmod(tmp, 0o600)
        tmp.replace(self.path)

    def consume(self, amount):
        if self.mode == "tc":
            return
        with self.lock:
            now = time.monotonic()
            start = max(now - self.capacity / self.rate, self.next_free)
            self.next_free = start + amount / self.rate
            wait = max(0.0, self.next_free - now)
            self.limited_bytes += int(amount)
            self.write()
        if wait:
            time.sleep(wait)

class ReceiverState:
    def __init__(self, root: Path):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.commits = self.root / "commits.jsonl"
        self.health = self.root / "receiver.json"
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.bucket = SharedBucket(root)
        self.write_health(0)

    def write_health(self, errors: int):
        tmp = self.health.with_suffix(".tmp")
        tmp.write_text(json.dumps({"status": "ok", "updated_at": time.time(), "errors": errors}) + "\n")
        os.chmod(tmp, 0o600)
        tmp.replace(self.health)

    def commit(self, item):
        with self.lock:
            with self.commits.open("a") as handle:
                handle.write(json.dumps(item, sort_keys=True) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
            self.write_health(0)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        state: ReceiverState = self.server.state
        self.request.settimeout(8.0)
        try:
            header = b""
            while b"\n" not in header and len(header) < 8192:
                piece = self.request.recv(1024)
                if not piece:
                    return
                header += piece
            header_line, buffered = header.split(b"\n", 1)
            spec = json.loads(header_line.decode())
            size = int(spec["size"])
            if size < 1 or size > 2_000_000:
                raise ValueError("invalid size")
            expected = str(spec["sha256"])
            digest = hashlib.sha256()
            buffered = buffered[:size]
            digest.update(buffered)
            received = len(buffered)
            state.bucket.consume(received)
            while received < size:
                piece = self.request.recv(min(65536, size - received))
                if not piece:
                    raise ConnectionError("short payload")
                received += len(piece)
                digest.update(piece)
                state.bucket.consume(len(piece))
            actual = digest.hexdigest()
            if actual != expected:
                raise ValueError("digest mismatch")
            item = {
                "kind": str(spec.get("kind", "unknown")),
                "name": str(spec.get("name", "unnamed")),
                "revision": str(spec.get("revision", "")),
                "size": size,
                "sha256": actual,
                "committed_at": time.time(),
                "peer": self.client_address[0],
            }
            state.commit(item)
            self.request.sendall((json.dumps({"committed": True, **item}) + "\n").encode())
        except Exception as exc:
            try:
                self.request.sendall((json.dumps({"committed": False, "error": type(exc).__name__}) + "\n").encode())
            except OSError:
                pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--pid-file")
    args = ap.parse_args()
    if args.pid_file:
        Path(args.pid_file).write_text(str(os.getpid()) + "\n")
        os.chmod(args.pid_file, 0o600)
    state = ReceiverState(Path(args.state))
    with Server((args.host, args.port), Handler) as server:
        server.state = state
        server.timeout = 0.25
        def stop(_sig, _frame):
            state.stop.set()
            threading.Thread(target=server.shutdown, daemon=True).start()
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        server.serve_forever(poll_interval=0.1)


if __name__ == "__main__":
    main()
