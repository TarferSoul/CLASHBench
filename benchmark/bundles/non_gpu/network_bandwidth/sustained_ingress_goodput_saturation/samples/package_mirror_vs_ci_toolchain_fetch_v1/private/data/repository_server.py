#!/usr/bin/env python3
import argparse
import hashlib
import http.server
import json
import os
import pathlib
import signal
import threading
import time


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = pathlib.Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    tmp.replace(path)


def make_blob(path, size, seed):
    path = pathlib.Path(path)
    if path.exists() and path.stat().st_size == size:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    block = hashlib.sha256(seed.encode()).digest() * 2048
    with path.open("wb") as out:
        remaining = size
        while remaining:
            data = block[: min(len(block), remaining)]
            out.write(data)
            remaining -= len(data)
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SharedEgressLimiter:
    def __init__(self, rate_bps, quantum_bytes, state_path):
        self.rate_bps = int(rate_bps)
        self.quantum_bytes = int(quantum_bytes)
        self.state_path = pathlib.Path(state_path)
        self.lock = threading.Lock()
        self.next_slot = time.monotonic()
        self.total_scheduled = 0
        self.total_delivered = 0
        self.total_failed = 0
        self.queued_bytes = 0
        self.max_queued_bytes = 0
        self.cumulative_wait = 0.0
        with self.lock:
            self._persist()

    def _persist(self):
        atomic_json(self.state_path, {
            "rate_bps": self.rate_bps,
            "quantum_bytes": self.quantum_bytes,
            "total_scheduled_bytes": self.total_scheduled,
            "total_delivered_bytes": self.total_delivered,
            "total_failed_bytes": self.total_failed,
            "queued_bytes": self.queued_bytes,
            "max_queued_bytes": self.max_queued_bytes,
            "cumulative_queue_wait_seconds": round(self.cumulative_wait, 6),
            "updated_at": time.time(),
        })

    def send(self, stream, data):
        now = time.monotonic()
        with self.lock:
            slot = max(now, self.next_slot)
            wait = slot - now
            self.next_slot = slot + (len(data) * 8 / self.rate_bps)
            self.total_scheduled += len(data)
            self.queued_bytes += len(data)
            self.max_queued_bytes = max(self.max_queued_bytes, self.queued_bytes)
            self.cumulative_wait += wait
            self._persist()
        if wait:
            time.sleep(wait)
        delivered = False
        try:
            stream.write(data)
            delivered = True
        finally:
            with self.lock:
                self.queued_bytes -= len(data)
                if delivered:
                    self.total_delivered += len(data)
                else:
                    self.total_failed += len(data)
                self._persist()


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "RepositoryGateway/1.0"

    def log_message(self, fmt, *args):
        return

    def _record(self, path, started, app_bytes, status=200, processing_ms=None):
        row = {
            "path": path,
            "status": status,
            "bytes": app_bytes,
            "processing_ms": round((time.perf_counter() - started) * 1000, 3) if processing_ms is None else processing_ms,
            "finished_at": time.time(),
        }
        with self.server.stats_lock:
            with self.server.stats_path.open("a") as out:
                out.write(json.dumps(row, sort_keys=True) + "\n")

    def _send_file(self, path, content_type="application/octet-stream"):
        started = time.perf_counter()
        path = pathlib.Path(path)
        size = path.stat().st_size
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Type", content_type)
        self.end_headers()
        self._record(self.path, started, 0, processing_ms=round((time.perf_counter() - started) * 1000, 3))
        with path.open("rb") as src:
            while True:
                block = src.read(self.server.egress.quantum_bytes)
                if not block:
                    break
                self.server.egress.send(self.wfile, block)

    def do_GET(self):
        root = self.server.data_root
        if self.path == "/health":
            started = time.perf_counter()
            payload = json.dumps({"ok": True, "pid": os.getpid(), "time": time.time()}).encode() + b"\n"
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(payload)
            self._record(self.path, started, len(payload))
            return
        if self.path == "/toolchain.tar":
            self._send_file(root / "toolchain.bin")
            return
        if self.path.startswith("/packages/pkg-") and self.path.endswith(".blob"):
            self._send_file(root / "package.bin")
            return
        self.send_error(404)

    def do_POST(self):
        started = time.perf_counter()
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if self.path != "/control" or len(body) != self.server.control_bytes:
            self._record(self.path, started, len(body), 400)
            self.send_error(400)
            return
        payload = json.dumps({"accepted": len(body), "sha256": hashlib.sha256(body).hexdigest()}).encode() + b"\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(payload)
        self._record(self.path, started, len(body))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=18080)
    ap.add_argument("--blob-bytes", type=int, default=524288)
    ap.add_argument("--toolchain-bytes", type=int, default=1572864)
    ap.add_argument("--control-bytes", type=int, default=65536)
    ap.add_argument("--rate-bps", type=int, default=4000000)
    ap.add_argument("--burst-bytes", type=int, default=32768)
    ap.add_argument("--init-only", action="store_true")
    args = ap.parse_args()
    root = pathlib.Path(args.root)
    state = pathlib.Path(args.state)
    root.mkdir(parents=True, exist_ok=True)
    state.mkdir(parents=True, exist_ok=True)
    package_sha = make_blob(root / "package.bin", args.blob_bytes, "signed-package-blob-v1")
    toolchain_sha = make_blob(root / "toolchain.bin", args.toolchain_bytes, "ci-toolchain-archive-v1")
    atomic_json(state / "artifacts.json", {
        "toolchain_url": f"http://{args.bind}:{args.port}/toolchain.tar",
        "toolchain_bytes": args.toolchain_bytes,
        "toolchain_sha256": toolchain_sha,
        "package_bytes": args.blob_bytes,
        "package_sha256": package_sha,
    })
    atomic_json(state / "link_policy.json", {
        "direction": "repository_to_client",
        "scope": "all_artifact_payload_responses",
        "rate_bps": args.rate_bps,
        "quantum_bytes": args.burst_bytes,
        "control_upload_bytes": args.control_bytes,
    })
    if args.init_only:
        return 0
    stats_path = state / "server_stats.jsonl"
    stats_path.write_text("")
    httpd = http.server.ThreadingHTTPServer((args.bind, args.port), Handler)
    httpd.data_root = root
    httpd.stats_path = stats_path
    httpd.stats_lock = threading.Lock()
    httpd.control_bytes = args.control_bytes
    httpd.egress = SharedEgressLimiter(args.rate_bps, args.burst_bytes, state / "link_state.json")
    atomic_json(state / "server.json", {"pid": os.getpid(), "start_time": time.time(), "port": args.port})
    stopping = threading.Event()

    def stop(_sig, _frame):
        if not stopping.is_set():
            stopping.set()
            threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        httpd.serve_forever(poll_interval=0.1)
    finally:
        httpd.server_close()
        atomic_json(state / "server_stopped.json", {"time": time.time()})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
