#!/usr/bin/env python3
import argparse
import ast
import hashlib
import io
import json
import marshal
import multiprocessing as mp
import os
import pathlib
import tarfile
import time
import zlib


def build_unit(modules, worker_index, sequence):
    digest = hashlib.sha256()
    compiled_size = 0
    for repeat in range(72):
        for module in modules:
            source = module["source"]
            tree = ast.parse(source, filename=module["name"] + ".py")
            ast.fix_missing_locations(tree)
            code = compile(tree, module["name"] + ".py", "exec", optimize=2)
            payload = marshal.dumps(code)
            for level in (1, 6, 9):
                payload = zlib.compress(payload, level)
                payload = zlib.decompress(payload)
            digest.update(payload)
            digest.update(f"{worker_index}:{sequence}:{repeat}".encode())
            compiled_size += len(payload)
    return digest.digest(), compiled_size


def worker(index, cpu, modules, counters, byte_counts, digest_values, stopping):
    os.sched_setaffinity(0, {cpu})
    sequence = 0
    while not stopping.is_set():
        digest, size = build_unit(modules, index, sequence)
        sequence += 1
        counters[index] = sequence
        byte_counts[index] += size
        digest_values[index] = int.from_bytes(digest[:8], "big")


def write_package(output, source, result):
    output.mkdir(parents=True, exist_ok=True)
    info = json.dumps(
        {
            "schema": "search-release-build-info-v1",
            "input_sha256": result["input_sha256"],
            "completed_units": result["completed_units"],
            "worker_count": result["worker_count"],
            "accepted": result["accepted"],
        },
        sort_keys=True,
    ).encode()
    archive = output / "release.tar.gz"
    with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as handle:
        for name, payload in (("release_sources.json", source), ("BUILD_INFO.json", info)):
            member = tarfile.TarInfo(name)
            member.size = len(payload)
            member.mtime = 0
            member.mode = 0o644
            handle.addfile(member, io.BytesIO(payload))
    result["artifact_sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "build_manifest.json").write_text(
        json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--job", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--trial-seconds", type=float)
    parser.add_argument("--report")
    args = parser.parse_args()
    source_path = pathlib.Path(args.input)
    source = source_path.read_bytes()
    spec = json.loads(source)
    job = json.loads(pathlib.Path(args.job).read_text())
    cpus = [int(value) for value in job["cpus"]]
    workers = int(job["workers"])
    if workers != len(cpus) or workers != 2:
        raise SystemExit("job must prescribe two workers on two CPUs")
    duration = float(args.trial_seconds or job["runtime_seconds"])
    context = mp.get_context("fork")
    counters = context.Array("Q", workers, lock=False)
    byte_counts = context.Array("Q", workers, lock=False)
    digest_values = context.Array("Q", workers, lock=False)
    stopping = context.Event()
    processes = []
    started = time.monotonic()
    for index, cpu in enumerate(cpus):
        process = context.Process(
            target=worker,
            args=(index, cpu, spec["modules"], counters, byte_counts, digest_values, stopping),
            name=f"release-compile-{index}",
        )
        process.start()
        processes.append(process)
    worker_pids = [process.pid for process in processes]
    deadline = started + duration
    try:
        while time.monotonic() < deadline and all(process.is_alive() for process in processes):
            time.sleep(0.03)
    finally:
        stopping.set()
        for process in processes:
            process.join(timeout=3)
        for process in processes:
            if process.is_alive():
                process.terminate()
                process.join(timeout=1)
    elapsed = time.monotonic() - started
    completed = int(sum(counters))
    rate = completed / elapsed if elapsed else 0.0
    minimum_rate = float(job.get("minimum_units_per_second", 0.0))
    result = {
        "schema": "search-release-build-manifest-v1",
        "accepted": rate >= minimum_rate and all(value > 0 for value in counters),
        "completed_units": completed,
        "compiled_bytes": int(sum(byte_counts)),
        "elapsed_seconds": elapsed,
        "units_per_second": rate,
        "minimum_units_per_second": minimum_rate,
        "worker_count": workers,
        "worker_pids": worker_pids,
        "worker_units": list(counters),
        "cpu_list": cpus,
        "input_sha256": hashlib.sha256(source).hexdigest(),
        "build_digest": hashlib.sha256(
            ",".join(str(value) for value in digest_values).encode()
        ).hexdigest(),
    }
    output = pathlib.Path(args.output)
    write_package(output, source, result)
    if args.report:
        pathlib.Path(args.report).write_text(
            json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8"
        )
    print(json.dumps({key: result[key] for key in ("accepted", "completed_units", "units_per_second")}))
    if not args.trial_seconds and not result["accepted"]:
        raise SystemExit(4)


if __name__ == "__main__":
    main()
