#!/usr/bin/env python3
"""Continuously publish useful, receiver-verified chunks through one egress lane."""
import argparse
import hashlib
import json
import os
import signal
import socket
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


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


class Publisher:
    def __init__(self, args):
        self.args = args
        self.root = Path(args.state)
        self.root.mkdir(parents=True, exist_ok=True)
        self.progress_path = self.root / "publisher_progress.json"
        self.events_path = self.root / "publisher_events.jsonl"
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.progress = {
            "context": args.context,
            "kind": args.kind,
            "workers": args.workers,
            "chunk_bytes": args.chunk_bytes,
            "started_at": time.time(),
            "committed_chunks": 0,
            "committed_bytes": 0,
            "errors": 0,
            "last_commit_at": None,
            "last_names": [],
        }
        atomic_json(self.progress_path, self.progress)

    def record(self, value=None, error=None):
        with self.lock:
            if value:
                self.progress["committed_chunks"] += 1
                self.progress["committed_bytes"] += int(value["size"])
                self.progress["last_commit_at"] = time.time()
                self.progress["last_names"] = (self.progress["last_names"] + [value["name"]])[-8:]
            if error:
                self.progress["errors"] += 1
            atomic_json(self.progress_path, self.progress)
            with self.events_path.open("a") as handle:
                handle.write(json.dumps({"at": time.time(), "commit": value, "error": error}, sort_keys=True) + "\n")

    def send(self, worker, sequence):
        name = f"{self.args.prefix}-w{worker}-{sequence:06d}"
        payload = deterministic_bytes(f"{self.args.context}:{name}", self.args.chunk_bytes)
        digest = hashlib.sha256(payload).hexdigest()
        header = {
            "stream": "incumbent",
            "kind": self.args.kind,
            "name": name,
            "revision": self.args.revision,
            "size": len(payload),
            "sha256": digest,
        }
        with socket.create_connection((self.args.host, self.args.port), timeout=20.0) as connection:
            connection.settimeout(20.0)
            connection.sendall((json.dumps(header, sort_keys=True) + "\n").encode() + payload)
            response = b""
            while not response.endswith(b"\n"):
                piece = connection.recv(4096)
                if not piece:
                    raise ConnectionError("receiver closed before commit")
                response += piece
        receipt = json.loads(response.decode())
        if receipt.get("committed") is not True or receipt.get("sha256") != digest:
            raise RuntimeError("receiver did not commit incumbent chunk")
        return {"name": name, "size": len(payload), "sha256": digest, "worker": worker, "sequence": sequence}

    def worker(self, worker):
        sequence = 0
        while not self.stop.is_set():
            sequence += 1
            try:
                self.record(value=self.send(worker, sequence))
            except Exception as exc:
                if not self.stop.is_set():
                    self.record(error=type(exc).__name__)
                    time.sleep(0.05)

    def run(self):
        workers = [threading.Thread(target=self.worker, args=(index,), daemon=True) for index in range(self.args.workers)]
        for worker in workers:
            worker.start()
        while not self.stop.wait(0.2):
            pass
        for worker in workers:
            worker.join(timeout=2.0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--context", required=True)
    parser.add_argument("--kind", required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--chunk-bytes", type=int, required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()
    Path(args.pid_file).write_text(str(os.getpid()) + "\n")
    os.chmod(args.pid_file, 0o600)
    publisher = Publisher(args)
    signal.signal(signal.SIGTERM, lambda _signal, _frame: publisher.stop.set())
    signal.signal(signal.SIGINT, lambda _signal, _frame: publisher.stop.set())
    publisher.run()


if __name__ == "__main__":
    main()

