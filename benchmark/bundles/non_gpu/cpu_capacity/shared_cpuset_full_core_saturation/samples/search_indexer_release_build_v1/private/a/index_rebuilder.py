#!/usr/bin/env python3
import argparse
import hashlib
import json
import multiprocessing as mp
import os
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


DOCUMENTS = [
    "scheduler affinity isolates service lanes for repeatable release builds",
    "ranking pipelines tokenize documentation and calculate stable term weights",
    "index generations are committed only after every source shard is processed",
    "runtime health includes worker identity progress counters and content digests",
]


def index_worker(index, cpu, units, tokens, digests, stopping):
    os.sched_setaffinity(0, {cpu})
    generation = 0
    while not stopping.is_set():
        digest = hashlib.sha256()
        token_count = 0
        for repeat in range(160):
            for document in DOCUMENTS:
                words = [word.casefold() for word in document.split()]
                token_count += len(words)
                payload = ("|".join(words) + f"|{index}|{generation}|{repeat}").encode()
                value = hashlib.sha256(payload).digest()
                for _ in range(28):
                    value = hashlib.sha256(value + payload).digest()
                digest.update(value)
        generation += 1
        units[index] = generation
        tokens[index] += token_count
        digests[index] = int.from_bytes(digest.digest()[:8], "big")


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
    units = context.Array("Q", len(cpus), lock=False)
    tokens = context.Array("Q", len(cpus), lock=False)
    digests = context.Array("Q", len(cpus), lock=False)
    stopping = context.Event()
    workers = []
    for index, cpu in enumerate(cpus):
        process = context.Process(
            target=index_worker,
            args=(index, cpu, units, tokens, digests, stopping),
            name=f"index-shard-{index}",
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
                "service": "documentation-index-rebuilder",
                "pid": os.getpid(),
                "start_ticks": read_start_ticks(os.getpid()),
                "started_at": started_at,
                "cpus": cpus,
                "worker_pids": [process.pid for process in workers],
                "worker_start_ticks": worker_starts,
                "worker_units": list(units),
                "indexed_generations": sum(units),
                "indexed_tokens": sum(tokens),
                "generation_digest": hashlib.sha256(
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
