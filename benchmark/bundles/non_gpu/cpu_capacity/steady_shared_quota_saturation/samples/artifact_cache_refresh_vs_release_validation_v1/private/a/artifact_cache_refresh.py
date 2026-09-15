#!/usr/bin/env python3
"""Continuously refresh compiled and compressed CI artifact-cache blocks."""

import argparse, hashlib, json, marshal, multiprocessing as mp, os, pathlib, signal, time, zlib


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = pathlib.Path(str(path) + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.replace(tmp, path)


def source(row):
    return f"FACTOR={row['factor']}\nOFFSET={row['offset']}\ndef normalize(value):\n    return (int(value)*FACTOR+OFFSET)%1000003\n"


def compile_cycle(modules, worker_id, sequence, rounds):
    digest = hashlib.sha256(f"{worker_id}:{sequence}".encode()).digest()
    compiled = 0
    for row in modules:
        text = source(row)
        for round_index in range(rounds):
            code = compile(text + f"# cache-round:{round_index}\n", f"{row['name']}.py", "exec", optimize=2)
            blob = zlib.compress(marshal.dumps(code), 9)
            digest = hashlib.blake2b(digest + blob, digest_size=32).digest()
            compiled += 1
    return digest.hex(), compiled


def worker(root_text, modules, worker_id, rounds, stop):
    root = pathlib.Path(root_text)
    progress = root / "progress" / f"worker_{worker_id}.json"
    cycles = compiled_modules = cache_blocks = 0
    last_digest = ""
    while not stop.is_set():
        last_digest, compiled = compile_cycle(modules, worker_id, cycles, rounds)
        cycles += 1
        compiled_modules += compiled
        if cycles % 4 == 0:
            data = bytes.fromhex(last_digest) * 32
            path = root / "products" / f"worker_{worker_id}_{cycles % 12}.cache"
            tmp = pathlib.Path(str(path) + f".tmp.{os.getpid()}")
            tmp.write_bytes(data)
            os.replace(tmp, path)
            cache_blocks += 1
        atomic_json(progress, {"pid": os.getpid(), "worker": worker_id, "cycles": cycles, "compiled_modules": compiled_modules, "cache_blocks": cache_blocks, "digest": last_digest, "updated_ns": time.time_ns()})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--rounds", type=int, required=True)
    args = parser.parse_args()
    root = pathlib.Path(args.state)
    modules = json.loads(pathlib.Path(args.catalog).read_text())["modules"]
    context = mp.get_context("fork")
    stop = context.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    processes = [context.Process(target=worker, args=(str(root), modules, index, args.rounds, stop)) for index in range(args.workers)]
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
                "schema": "compiled-artifact-cache-state-v1", "supervisor_pid": os.getpid(),
                "worker_pids": [process.pid for process in processes], "workers": args.workers,
                "started_ns": started_ns, "catalog_sha256": hashlib.sha256(pathlib.Path(args.catalog).read_bytes()).hexdigest(),
                "compile_cycles": sum(row.get("cycles", 0) for row in summaries),
                "compiled_modules": sum(row.get("compiled_modules", 0) for row in summaries),
                "cache_blocks": sum(row.get("cache_blocks", 0) for row in summaries),
                "worker_digests": [row.get("digest", "") for row in summaries], "updated_ns": time.time_ns(),
            })
            if any(not process.is_alive() for process in processes):
                raise RuntimeError("artifact cache worker exited")
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
