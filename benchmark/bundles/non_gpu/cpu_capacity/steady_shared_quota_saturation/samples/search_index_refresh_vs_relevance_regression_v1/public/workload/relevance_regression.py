#!/usr/bin/env python3
"""Run a deterministic, CPU-parallel retrieval relevance regression."""

import argparse
import hashlib
import json
import multiprocessing as mp
import os
import pathlib
import shutil
import sys
import time


def file_sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = pathlib.Path(str(path) + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def tokens(text):
    return [part for part in "".join(ch.lower() if ch.isalnum() else " " for ch in text).split() if part]


def stable_score(query, candidate):
    q = tokens(query)
    c = tokens(candidate)
    overlap = sum(c.count(token) for token in q)
    material = ("|".join(q) + "::" + "|".join(c)).encode()
    digest = hashlib.sha256(material).digest()
    tie = int.from_bytes(digest[:4], "big") / 2**32
    return round(overlap * 10.0 + tie, 8)


def cpu_unit(rows, offset):
    row = rows[offset % len(rows)]
    material = json.dumps(row, sort_keys=True).encode()
    digest = material
    accumulator = 0
    for round_index in range(96):
        digest = hashlib.blake2b(digest + round_index.to_bytes(2, "little"), digest_size=32).digest()
        accumulator ^= int.from_bytes(digest[:8], "little")
    for candidate in row["candidates"]:
        accumulator ^= int(stable_score(row["query"], candidate) * 1_000_000)
    return accumulator


def worker(rows, worker_index, start, stop, counter, digest_slot):
    start.wait()
    local_count = 0
    digest = worker_index + 1
    while not stop.is_set():
        digest ^= cpu_unit(rows, local_count + worker_index * 17)
        local_count += 1
        if local_count % 16 == 0:
            with counter.get_lock():
                counter.value += 16
    remainder = local_count % 16
    if remainder:
        with counter.get_lock():
            counter.value += remainder
    digest_slot.value = digest & ((1 << 63) - 1)


def measure(rows, workers, duration):
    context = mp.get_context("fork")
    start = context.Event()
    stop = context.Event()
    counter = context.Value("Q", 0)
    digests = [context.Value("Q", 0) for _ in range(workers)]
    processes = [
        context.Process(target=worker, args=(rows, index, start, stop, counter, digests[index]))
        for index in range(workers)
    ]
    for process in processes:
        process.start()
    began = time.monotonic()
    start.set()
    deadline = began + duration
    while time.monotonic() < deadline:
        time.sleep(min(0.02, max(0.0, deadline - time.monotonic())))
    stop.set()
    for process in processes:
        process.join(5)
    if any(process.is_alive() for process in processes):
        for process in processes:
            process.terminate()
        raise RuntimeError("scoring worker did not stop")
    elapsed = time.monotonic() - began
    return {
        "processed_units": int(counter.value),
        "elapsed_seconds": elapsed,
        "workers": workers,
        "worker_pids": [process.pid for process in processes],
        "kernel_digest": format(sum(slot.value for slot in digests) % (1 << 64), "016x"),
    }


def score_rows(rows):
    output = []
    for row in rows:
        ranked = sorted(
            ({"candidate": candidate, "score": stable_score(row["query"], candidate)} for candidate in row["candidates"]),
            key=lambda item: (-item["score"], item["candidate"]),
        )
        output.append({"query_id": row["id"], "ranking": ranked})
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--calibrate", action="store_true")
    parser.add_argument("--measure", action="store_true")
    parser.add_argument("--input")
    parser.add_argument("--workers", type=int)
    parser.add_argument("--duration", type=float)
    parser.add_argument("--job")
    parser.add_argument("--output")
    args = parser.parse_args()

    if args.calibrate or args.measure:
        if not args.input or not args.workers or not args.duration:
            parser.error("measurement requires --input, --workers, and --duration")
        fixture = json.loads(pathlib.Path(args.input).read_text())
        result = measure(fixture["queries"], args.workers, args.duration)
        result.update({"schema": "relevance-throughput-measurement-v1", "input_sha256": file_sha256(args.input)})
        print(json.dumps(result, sort_keys=True))
        return 0

    if not args.job or not args.output:
        parser.error("task execution requires --job and --output")
    job_path = pathlib.Path(args.job)
    job = json.loads(job_path.read_text())
    input_path = pathlib.Path(job["input_path"])
    if file_sha256(input_path) != job["input_sha256"]:
        raise SystemExit("frozen relevance input digest mismatch")
    fixture = json.loads(input_path.read_text())
    output = pathlib.Path(args.output)
    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(parents=True)

    measured = measure(fixture["queries"], int(job["workers"]), float(job["duration_seconds"]))
    scores_path = output / "scores.jsonl"
    with scores_path.open("w", encoding="utf-8") as stream:
        for row in score_rows(fixture["queries"]):
            stream.write(json.dumps(row, sort_keys=True) + "\n")
    scores_digest = file_sha256(scores_path)
    (output / "scores.sha256").write_text(f"{scores_digest}  scores.jsonl\n")
    complete = measured["processed_units"] >= int(job["target_units"])
    report = {
        "schema": "relevance-regression-report-v1",
        "complete": complete,
        "processed_units": measured["processed_units"],
        "target_units": int(job["target_units"]),
        "elapsed_seconds": measured["elapsed_seconds"],
        "workers": measured["workers"],
        "query_count": len(fixture["queries"]),
        "scores_sha256": scores_digest,
        "input_sha256": job["input_sha256"],
        "job_sha256": file_sha256(job_path),
        "kernel_digest": measured["kernel_digest"],
    }
    atomic_json(output / "report.json", report)
    print(json.dumps(report, sort_keys=True))
    return 0 if complete else 3


if __name__ == "__main__":
    sys.exit(main())
