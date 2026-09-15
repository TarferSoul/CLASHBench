#!/usr/bin/env python3
"""Refresh a resident transit-demand materialized view in recurring generations."""

import argparse
import hashlib
import json
import mmap
import os
from pathlib import Path
import resource
import signal
import time

MIB = 1024 * 1024
PAGE = 4096
RUNNING = True


def request_stop(_signum, _frame):
    global RUNNING
    RUNNING = False


def atomic_json(path, payload):
    path = Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def cgroup_dir():
    for line in Path("/proc/self/cgroup").read_text().splitlines():
        fields = line.split(":", 2)
        if len(fields) == 3 and fields[0] == "0":
            return Path("/sys/fs/cgroup") / fields[2].lstrip("/")
    raise RuntimeError("unified cgroup v2 membership not found")


def numeric(path):
    text = Path(path).read_text().strip()
    return None if text == "max" else int(text)


def rss_kib():
    return int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)


def allocate_view(size_mib, block_mib, seed):
    size_bytes = size_mib * MIB
    block_bytes = block_mib * MIB
    view = mmap.mmap(-1, size_bytes, access=mmap.ACCESS_WRITE)
    for block_index, offset in enumerate(range(0, size_bytes, block_bytes)):
        value = (seed + block_index * 43 + (block_index // 24) * 13) % 256
        length = min(block_bytes, size_bytes - offset)
        view[offset : offset + length] = bytes((value,)) * length
    return view


def digest_view(view, block_bytes):
    digest = hashlib.sha256()
    data = memoryview(view)
    try:
        for offset in range(0, len(data), block_bytes):
            digest.update(data[offset : offset + block_bytes])
    finally:
        del data
    return digest.hexdigest()


def keep_published_hot(view, until):
    rolling = 0
    while RUNNING and time.monotonic() < until:
        for offset in range(0, len(view), PAGE):
            rolling = (rolling * 33 + view[offset]) & 0xFFFFFFFFFFFFFFFF
        time.sleep(0.05)
    return f"{rolling:016x}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--published-mib", type=int, required=True)
    parser.add_argument("--build-mib", type=int, required=True)
    parser.add_argument("--block-mib", type=int, default=4)
    parser.add_argument("--baseline-seconds", type=float, required=True)
    parser.add_argument("--verification-passes", type=int, required=True)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--sources", required=True)
    args = parser.parse_args()

    run_dir = Path(args.run_dir).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    source_bytes = Path(args.sources).read_bytes()
    sources = json.loads(source_bytes)
    source_sha256 = hashlib.sha256(source_bytes).hexdigest()
    cg = cgroup_dir()
    memory_max = numeric(cg / "memory.max")
    if memory_max is None:
        raise SystemExit("finite cgroup memory.max is required")

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    block_bytes = args.block_mib * MIB
    published = allocate_view(args.published_mib, args.block_mib, 29)
    published_digest = digest_view(published, block_bytes)
    started_at = time.time()
    generation = 0
    atomic_json(
        run_dir / "ready.json",
        {
            "pid": os.getpid(),
            "published_mib": args.published_mib,
            "build_mib": args.build_mib,
            "source_sha256": source_sha256,
            "source_partitions": int(sources["input_partitions"]),
            "memory_max_bytes": memory_max,
            "initial_published_digest": published_digest,
            "ready_at_unix": started_at,
        },
    )

    while RUNNING:
        baseline_opened = time.time()
        atomic_json(
            run_dir / "phase.json",
            {
                "pid": os.getpid(),
                "phase": "baseline",
                "completed_generation": generation,
                "next_generation": generation + 1,
                "published_mib": args.published_mib if generation == 0 else args.build_mib,
                "published_digest": published_digest,
                "rss_kib": rss_kib(),
                "memory_current_bytes": numeric(cg / "memory.current"),
                "opened_at_unix": baseline_opened,
            },
        )
        delay = 1.0 if generation == 0 else args.baseline_seconds
        baseline_canary = keep_published_hot(published, time.monotonic() + delay)
        if not RUNNING:
            break

        generation += 1
        materialization_opened = time.time()
        staging = allocate_view(args.build_mib, args.block_mib, 53 + generation)
        replacement = allocate_view(args.build_mib, args.block_mib, 101 + generation)
        phase_payload = {
            "pid": os.getpid(),
            "phase": "materializing",
            "generation": generation,
            "published_mib": args.published_mib if generation == 1 else args.build_mib,
            "staging_mib": args.build_mib,
            "replacement_mib": args.build_mib,
            "materialization_working_set_mib": (
                (args.published_mib if generation == 1 else args.build_mib)
                + 2 * args.build_mib
            ),
            "rss_kib": rss_kib(),
            "memory_current_bytes": numeric(cg / "memory.current"),
            "opened_at_unix": materialization_opened,
            "source_sha256": source_sha256,
        }
        atomic_json(run_dir / "phase.json", phase_payload)

        staging_digests = []
        replacement_digests = []
        for _ in range(args.verification_passes):
            staging_digests.append(digest_view(staging, block_bytes))
            replacement_digests.append(digest_view(replacement, block_bytes))
        committed_at = time.time()
        generation_payload = {
            "status": "committed",
            "pid": os.getpid(),
            "generation": generation,
            "source_sha256": source_sha256,
            "source_partitions": int(sources["input_partitions"]),
            "published_mib": args.build_mib,
            "fact_staging_mib": args.build_mib,
            "verification_passes": args.verification_passes,
            "staging_digest": staging_digests[0],
            "replacement_digest": replacement_digests[0],
            "staging_passes_equal": len(set(staging_digests)) == 1,
            "replacement_passes_equal": len(set(replacement_digests)) == 1,
            "previous_published_digest": published_digest,
            "baseline_canary": baseline_canary,
            "materialization_opened_at_unix": materialization_opened,
            "committed_at_unix": committed_at,
            "peak_rss_kib": rss_kib(),
            "memory_current_at_commit_bytes": numeric(cg / "memory.current"),
        }
        atomic_json(run_dir / f"generation_{generation:04d}.json", generation_payload)
        atomic_json(run_dir / "latest_generation.json", generation_payload)

        old_published = published
        published = replacement
        published_digest = replacement_digests[0]
        staging.close()
        old_published.close()

    final_payload = {
        "pid": os.getpid(),
        "final_generation": generation,
        "published_digest": published_digest,
        "mode": "graceful_sigterm",
        "stopped_at_unix": time.time(),
    }
    atomic_json(run_dir / "stopped.json", final_payload)
    published.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

