#!/usr/bin/env python3
import argparse
import hashlib
import json
import multiprocessing as mp
import os
import signal
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SERVICES = ["gateway", "retrieval", "reranker", "catalog", "scheduler"]


def rollup_worker(index, cpu, batches, events, compressed, digests, stopping):
    os.sched_setaffinity(0, {cpu})
    sequence = 0
    while not stopping.is_set():
        rows = []
        for offset in range(720):
            value = (sequence * 131 + offset * 17 + index * 29) % 100003
            rows.append(
                {
                    "service": SERVICES[(offset + index) % len(SERVICES)],
                    "minute": (sequence + offset) % 1440,
                    "count": 1 + value % 97,
                    "latency_sum": value * 7,
                    "error_count": value % 5,
                }
            )
        canonical = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
        blob = canonical
        for _ in range(18):
            blob = zlib.compress(blob, 6)
            blob = zlib.decompress(blob)
        encoded = zlib.compress(blob, 9)
        sequence += 1
        batches[index] = sequence
        events[index] += len(rows)
        compressed[index] += len(encoded)
        digests[index] = int.from_bytes(hashlib.sha256(encoded).digest()[:8], "big")


def read_start_ticks(pid):
    return int(open(f"/proc/{pid}/stat", encoding="utf-8").read().split()[21])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cpus", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    cpus = [int(value) for value in args.cpus.split(",") if value]
    if len(cpus) != 2:
        raise SystemExit("exactly two CPUs are required")
    os.sched_setaffinity(0, set(cpus))
    context = mp.get_context("fork")
    batches = context.Array("Q", len(cpus), lock=False)
    events = context.Array("Q", len(cpus), lock=False)
    compressed = context.Array("Q", len(cpus), lock=False)
    digests = context.Array("Q", len(cpus), lock=False)
    stopping = context.Event()
    workers = []
    for index, cpu in enumerate(cpus):
        process = context.Process(
            target=rollup_worker,
            args=(index, cpu, batches, events, compressed, digests, stopping),
            name=f"rollup-partition-{index}",
        )
        process.start()
        workers.append(process)

    started_at = time.time()
    worker_starts = [read_start_ticks(process.pid) for process in workers]

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in {"/health", "/metrics"}:
                self.send_response(404)
                self.end_headers()
                return
            payload = {
                "ok": all(process.is_alive() for process in workers),
                "service": "telemetry-rollup-pipeline",
                "pid": os.getpid(),
                "start_ticks": read_start_ticks(os.getpid()),
                "started_at": started_at,
                "cpus": cpus,
                "worker_pids": [process.pid for process in workers],
                "worker_start_ticks": worker_starts,
                "worker_units": list(batches),
                "committed_batches": sum(batches),
                "rolled_events": sum(events),
                "compressed_bytes": sum(compressed),
                "rollup_digest": hashlib.sha256(
                    ",".join(str(value) for value in digests).encode()
                ).hexdigest(),
            }
            body = json.dumps(payload, sort_keys=True).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format, *_args):
            return

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.timeout = 0.25

    def stop(_signum, _frame):
        stopping.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        while not stopping.is_set():
            server.handle_request()
    finally:
        stopping.set()
        server.server_close()
        for process in workers:
            process.join(timeout=2)
        for process in workers:
            if process.is_alive():
                process.terminate()
                process.join(timeout=1)


if __name__ == "__main__":
    main()
