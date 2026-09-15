#!/usr/bin/env python3
import argparse
import collections
import concurrent.futures
import hashlib
import json
import pathlib
import re
import signal
import threading
import time

TOKEN_RE = re.compile(r"[a-z0-9_]+")


def atomic_json(path, value):
    tmp = pathlib.Path(str(path) + f".tmp.{threading.get_ident()}")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    tmp.replace(path)


def index_partition(index, paths, state_root, stopping, ready, counters, lock, workers):
    passes = 0
    while not stopping.is_set():
        digest = hashlib.sha256()
        symbols = collections.Counter()
        bytes_read = 0
        for path in paths:
            raw = path.read_bytes()
            record = json.loads(raw)
            digest.update(raw)
            bytes_read += len(raw)
            symbols.update(TOKEN_RE.findall(" ".join(record["symbols"])))
        passes += 1
        atomic_json(state_root / "partitions" / f"partition-{index:02d}.json", {
            "worker": index, "files": len(paths), "bytes_read": bytes_read,
            "source_digest": digest.hexdigest(), "top_symbols": symbols.most_common(10), "passes": passes,
        })
        with lock:
            counters["indexed_files"] += len(paths)
            counters["completed_partitions"] += 1
            counters["worker_passes"][index] = passes
        ready[index].set()
        stopping.wait(0.35)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--workers", required=True, type=int)
    args = parser.parse_args()
    source, state = pathlib.Path(args.source), pathlib.Path(args.state)
    paths = sorted(source.glob("*.json"))
    if args.workers < 1 or len(paths) < args.workers:
        raise SystemExit("source corpus must cover every worker")
    state.mkdir(parents=True, exist_ok=True)
    (state / "partitions").mkdir(exist_ok=True)
    stopping = threading.Event()
    ready = [threading.Event() for _ in range(args.workers)]
    lock = threading.Lock()
    counters = {"indexed_files": 0, "completed_partitions": 0, "worker_passes": [0] * args.workers}

    def stop(_signum, _frame):
        stopping.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    started_ns = time.time_ns()
    assignments = [paths[index::args.workers] for index in range(args.workers)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers, thread_name_prefix="symbol-parse") as pool:
        futures = [pool.submit(index_partition, index, assignments[index], state, stopping, ready, counters, lock, args.workers) for index in range(args.workers)]
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not all(item.is_set() for item in ready):
            if any(future.done() and future.exception() for future in futures):
                raise RuntimeError("index worker exited during startup")
            time.sleep(0.05)
        if not all(item.is_set() for item in ready):
            raise RuntimeError("index worker cohort did not become ready")
        while not stopping.is_set():
            with lock:
                snapshot = {"indexed_files": counters["indexed_files"], "completed_partitions": counters["completed_partitions"], "minimum_worker_passes": min(counters["worker_passes"])}
            alive = sum(not future.done() for future in futures)
            native_threads = len(list(pathlib.Path(f"/proc/{__import__('os').getpid()}/task").iterdir()))
            atomic_json(state / "status.json", {"healthy": alive == args.workers, "pid": __import__('os').getpid(), "started_ns": started_ns, "source_records": len(paths), "worker_count": args.workers, "workers_alive": alive, "native_threads": native_threads, **snapshot, "updated_ns": time.time_ns()})
            stopping.wait(0.2)
        for future in futures:
            future.result(timeout=5)


if __name__ == "__main__":
    main()
