#!/usr/bin/env python3
"""Feature-index training worker with durable checkpoint publication."""

import hashlib
import json
import os
import pathlib
import shutil
import signal
import sys
import threading
import time


STOP = False


def handle_stop(signum, frame):
    del signum, frame
    global STOP
    STOP = True


signal.signal(signal.SIGTERM, handle_stop)
signal.signal(signal.SIGINT, handle_stop)


def fsync_dir(path: pathlib.Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path: pathlib.Path, value: dict) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    with tmp.open("rb") as handle:
        os.fsync(handle.fileno())
    os.replace(tmp, path)
    fsync_dir(path.parent)


def make_chunk(seed: str, generation: int, shard: int, chunk_index: int, size: int) -> bytes:
    base = hashlib.sha256(f"{seed}:{generation}:{shard}:{chunk_index}".encode()).digest()
    return (base * ((size // len(base)) + 1))[:size]


def write_shard(path: pathlib.Path, seed: str, generation: int, shard: int, total: int, chunk_bytes: int, results: dict) -> None:
    digest = hashlib.sha256()
    fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o640)
    try:
        remaining = total
        chunk_index = 0
        while remaining > 0 and not STOP:
            size = min(chunk_bytes, remaining)
            data = make_chunk(seed, generation, shard, chunk_index, size)
            os.write(fd, data)
            digest.update(data)
            remaining -= size
            chunk_index += 1
        os.fsync(fd)
    finally:
        os.close(fd)
    results[shard] = digest.hexdigest()


def wait_for_release(gate_dir: pathlib.Path, generation: int) -> None:
    if not gate_dir:
        return
    gate_dir.mkdir(parents=True, exist_ok=True)
    ready = gate_dir / f"ready_{generation}"
    release = gate_dir / f"release_{generation}"
    ready.write_text(str(time.time()) + "\n")
    while not STOP and not release.exists():
        time.sleep(0.02)


def main() -> int:
    root = pathlib.Path(os.environ["A_RUNTIME_ROOT"])
    checkpoint_root = root / "checkpoints"
    state = root / "state.json"
    stop_file = root / "stop"
    gate_value = os.environ.get("A_PHASE_GATE_DIR", "")
    gate_dir = pathlib.Path(gate_value) if gate_value else None
    wait_release = os.environ.get("A_WAIT_FOR_RELEASE", "0") == "1"
    shard_count = int(os.environ.get("A_SHARD_COUNT", "6"))
    shard_bytes = int(os.environ.get("A_SHARD_BYTES", str(96 * 1024 * 1024)))
    chunk_bytes = int(os.environ.get("A_CHUNK_BYTES", str(1024 * 1024)))
    compute_seconds = float(os.environ.get("A_COMPUTE_SECONDS", "0.2"))
    keep_generations = int(os.environ.get("A_KEEP_GENERATIONS", "1"))
    seed = os.environ.get("A_SEED", "feature-checkpoint-trainer")

    root.mkdir(parents=True, exist_ok=True)
    checkpoint_root.mkdir(parents=True, exist_ok=True)
    fsync_dir(root)
    generation = 0
    batches = 0
    started_at = time.time()

    while not STOP and not stop_file.exists():
        batches += 1
        atomic_json(state, {
            "pid": os.getpid(),
            "started_at": started_at,
            "phase": "ingest_compute",
            "generation": generation,
            "embedding_batches": batches,
            "updated_at": time.time(),
        })
        end_compute = time.monotonic() + compute_seconds
        accumulator = 0
        while time.monotonic() < end_compute and not STOP and not stop_file.exists():
            for value in range(2500):
                accumulator = (accumulator + value * 17) % 104729

        next_generation = generation + 1
        atomic_json(state, {
            "pid": os.getpid(),
            "started_at": started_at,
            "phase": "checkpoint_ready",
            "generation": generation,
            "pending_generation": next_generation,
            "embedding_batches": batches,
            "updated_at": time.time(),
        })
        if wait_release and gate_dir is not None:
            wait_for_release(gate_dir, next_generation)
        if STOP or stop_file.exists():
            break

        atomic_json(state, {
            "pid": os.getpid(),
            "started_at": started_at,
            "phase": "checkpoint_write",
            "generation": generation,
            "pending_generation": next_generation,
            "embedding_batches": batches,
            "updated_at": time.time(),
        })
        tmp = checkpoint_root / f"generation_{next_generation:04d}.tmp"
        final = checkpoint_root / f"generation_{next_generation:04d}"
        if tmp.exists():
            shutil.rmtree(tmp)
        tmp.mkdir()
        shard_dir = tmp / "shards"
        shard_dir.mkdir()
        results = {}
        threads = []
        for shard in range(shard_count):
            path = shard_dir / f"model_state_{shard:03d}.bin"
            thread = threading.Thread(
                target=write_shard,
                args=(path, seed, next_generation, shard, shard_bytes, chunk_bytes, results),
            )
            thread.start()
            threads.append(thread)
        for thread in threads:
            thread.join()
        if STOP or stop_file.exists():
            break
        manifest = {
            "format": "feature-index-checkpoint-v1",
            "generation": next_generation,
            "embedding_batches": batches,
            "total_bytes": shard_count * shard_bytes,
            "shards": [
                {
                    "name": f"shards/model_state_{shard:03d}.bin",
                    "bytes": shard_bytes,
                    "sha256": results[shard],
                }
                for shard in range(shard_count)
            ],
            "published_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        atomic_json(tmp / "manifest.json", manifest)
        if final.exists():
            shutil.rmtree(final)
        os.replace(tmp, final)
        fsync_dir(checkpoint_root)
        latest = checkpoint_root / "latest"
        latest_tmp = checkpoint_root / "latest.tmp"
        if latest_tmp.exists() or latest_tmp.is_symlink():
            latest_tmp.unlink()
        latest_tmp.symlink_to(final.name)
        os.replace(latest_tmp, latest)
        fsync_dir(checkpoint_root)
        generation = next_generation
        for old in sorted(checkpoint_root.glob("generation_*")):
            if old.is_dir() and not old.name.endswith(".tmp"):
                try:
                    old_generation = int(old.name.split("_")[1])
                except Exception:
                    continue
                if old_generation <= generation - keep_generations:
                    shutil.rmtree(old, ignore_errors=True)
        atomic_json(state, {
            "pid": os.getpid(),
            "started_at": started_at,
            "phase": "checkpoint_published",
            "generation": generation,
            "embedding_batches": batches,
            "latest_manifest": str((final / "manifest.json").resolve()),
            "total_checkpoint_bytes": shard_count * shard_bytes,
            "updated_at": time.time(),
        })

    atomic_json(state, {
        "pid": os.getpid(),
        "started_at": started_at,
        "phase": "stopping",
        "generation": generation,
        "embedding_batches": batches,
        "updated_at": time.time(),
    })
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"checkpoint_trainer_error={exc}", file=sys.stderr)
        raise
