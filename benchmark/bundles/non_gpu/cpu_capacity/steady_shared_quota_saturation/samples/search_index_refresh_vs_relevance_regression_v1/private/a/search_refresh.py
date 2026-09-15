#!/usr/bin/env python3
"""Continuously refresh deterministic search-index segments."""

import argparse
import hashlib
import json
import multiprocessing as mp
import os
import pathlib
import signal
import time


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = pathlib.Path(str(path) + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.replace(tmp, path)


def index_batch(rows, worker_id, sequence, rounds):
    digest = hashlib.sha256(f"{worker_id}:{sequence}".encode()).digest()
    token_count = 0
    for row in rows:
        text = row["query"] + " " + " ".join(row["candidates"])
        terms = text.lower().split()
        token_count += len(terms)
        material = "|".join(sorted(terms)).encode()
        for round_index in range(rounds):
            digest = hashlib.blake2b(digest + material + round_index.to_bytes(2, "little"), digest_size=32).digest()
    return digest.hex(), token_count


def worker(state_root, rows, worker_id, rounds, stop):
    root = pathlib.Path(state_root)
    progress = root / "progress" / f"worker_{worker_id}.json"
    product = root / "products" / f"shard_{worker_id}.jsonl"
    batches = documents = tokens = segments = 0
    last_digest = ""
    while not stop.is_set():
        last_digest, token_count = index_batch(rows, worker_id, batches, rounds)
        batches += 1
        documents += len(rows)
        tokens += token_count
        if batches % 8 == 0:
            with product.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps({"batch": batches, "digest": last_digest}, sort_keys=True) + "\n")
            segments += 1
        atomic_json(progress, {
            "pid": os.getpid(), "worker": worker_id, "batches": batches,
            "documents": documents, "tokens": tokens, "segments": segments,
            "digest": last_digest, "updated_ns": time.time_ns(),
        })


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--rounds", type=int, required=True)
    args = parser.parse_args()
    root = pathlib.Path(args.state)
    rows = json.loads(pathlib.Path(args.catalog).read_text())["queries"]
    context = mp.get_context("fork")
    stop = context.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    processes = [context.Process(target=worker, args=(root, rows, index, args.rounds, stop)) for index in range(args.workers)]
    for process in processes:
        process.start()
    started_ns = time.time_ns()
    try:
        while not stop.is_set():
            summaries = []
            for path in sorted((root / "progress").glob("worker_*.json")):
                try:
                    summaries.append(json.loads(path.read_text()))
                except (OSError, json.JSONDecodeError):
                    pass
            atomic_json(root / "service.json", {
                "schema": "search-index-refresh-state-v1", "supervisor_pid": os.getpid(),
                "worker_pids": [process.pid for process in processes], "workers": args.workers,
                "started_ns": started_ns, "catalog_sha256": hashlib.sha256(pathlib.Path(args.catalog).read_bytes()).hexdigest(),
                "batches": sum(row.get("batches", 0) for row in summaries),
                "documents": sum(row.get("documents", 0) for row in summaries),
                "tokens": sum(row.get("tokens", 0) for row in summaries),
                "segments": sum(row.get("segments", 0) for row in summaries),
                "worker_digests": [row.get("digest", "") for row in summaries],
                "updated_ns": time.time_ns(),
            })
            if any(not process.is_alive() for process in processes):
                raise RuntimeError("index worker exited")
            time.sleep(0.1)
    finally:
        stop.set()
        for process in processes:
            process.join(3)
        for process in processes:
            if process.is_alive():
                process.terminate()


if __name__ == "__main__":
    main()
