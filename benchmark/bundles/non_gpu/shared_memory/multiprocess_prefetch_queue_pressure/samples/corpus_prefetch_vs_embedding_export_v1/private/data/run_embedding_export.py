#!/usr/bin/env python3
"""Multiprocess prefetch pipeline with unlinked POSIX shared-memory tensor slots."""

import argparse
import hashlib
import json
import math
import multiprocessing as mp
from multiprocessing import shared_memory
import os
from pathlib import Path
import queue
import signal
import sys
import time


PAGE = os.sysconf("SC_PAGE_SIZE")
WRITE_CHUNK = 256 * 1024


class SharedMemoryPressure(RuntimeError):
    pass


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(str(path) + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def embedding(record):
    payload = (record["text"] + "\0" + record["label"]).encode("utf-8")
    return list(hashlib.blake2b(payload, digest_size=16).digest())


def mount_bytes():
    info = os.statvfs("/dev/shm")
    return info.f_blocks * info.f_frsize


def mount_free_bytes():
    info = os.statvfs("/dev/shm")
    return info.f_bavail * info.f_frsize


def process_start_time(pid):
    fields = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").split()
    return int(fields[21])


def fill_slot(view, start, length, seed):
    pattern = hashlib.blake2b(seed, digest_size=64).digest()
    block = (pattern * ((WRITE_CHUNK + len(pattern) - 1) // len(pattern)))[:WRITE_CHUNK]
    cursor = start
    end = start + length
    while cursor < end:
        size = min(len(block), end - cursor)
        view[cursor : cursor + size] = block[:size]
        cursor += size


def worker_main(worker_id, segment, slot_bytes, task_queue, result_queue):
    view = segment.buf
    try:
        while True:
            task = task_queue.get()
            if task is None:
                break
            slot = task["slot"]
            records = task["records"]
            seed = json.dumps(records, sort_keys=True, separators=(",", ":")).encode("utf-8")
            fill_slot(view, slot * slot_bytes, slot_bytes, seed)
            values = [
                {"id": record["id"], "label": record["label"], "embedding": embedding(record)}
                for record in records
            ]
            result_queue.put(
                {
                    "worker": worker_id,
                    "slot": slot,
                    "sequence": task["sequence"],
                    "records": values,
                    "tensor_checksum": hashlib.sha256(seed).hexdigest(),
                }
            )
    finally:
        del view


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--mode", choices=("finite", "continuous"), default="finite")
    parser.add_argument("--state-file")
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--prefetch-factor", type=int, required=True)
    parser.add_argument("--batch-size", type=int, required=True)
    parser.add_argument("--required-items", type=int, required=True)
    parser.add_argument("--tensor-ratio", type=float, required=True)
    parser.add_argument("--consumer-delay", type=float, default=0.0)
    return parser.parse_args()


def main():
    args = parse_args()
    if args.workers < 2 or args.prefetch_factor < 2 or args.batch_size < 1:
        raise SystemExit("workers>=2, prefetch-factor>=2, and batch-size>=1 are required")
    if not 0.10 <= args.tensor_ratio <= 0.80:
        raise SystemExit("tensor-ratio must be between 0.10 and 0.80")

    input_path = Path(args.input)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    records = [json.loads(line) for line in input_path.read_text(encoding="utf-8").splitlines() if line]
    if not records:
        raise SystemExit("input corpus is empty")

    total = mount_bytes()
    target = int(total * args.tensor_ratio)
    target -= target % PAGE
    segment_bytes = (target // args.workers) // PAGE * PAGE
    slot_bytes = (segment_bytes // args.prefetch_factor) // PAGE * PAGE
    segment_bytes = slot_bytes * args.prefetch_factor
    target = segment_bytes * args.workers
    if slot_bytes < 1024 * 1024:
        raise SystemExit("/dev/shm is too small for the fixed prefetch recipe")

    recipe = {
        "workers": args.workers,
        "prefetch_factor": args.prefetch_factor,
        "batch_size": args.batch_size,
        "required_items": args.required_items,
        "tensor_ratio": args.tensor_ratio,
        "target_tensor_bytes": target,
        "slot_bytes": slot_bytes,
        "input_sha256": file_sha256(input_path),
    }
    recipe_hash = hashlib.sha256(
        json.dumps(recipe, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()

    segments = []
    processes = []
    task_queues = []
    ctx = mp.get_context("fork")
    results = ctx.Queue()
    stopping = False

    def stop_requested(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop_requested)
    signal.signal(signal.SIGINT, stop_requested)

    def cleanup():
        for task_queue in task_queues:
            try:
                task_queue.put_nowait(None)
            except Exception:
                pass
        for process in processes:
            process.join(timeout=0.5)
            if process.is_alive():
                process.terminate()
        for process in processes:
            process.join(timeout=1.0)
            if process.is_alive():
                process.kill()
                process.join(timeout=1.0)
        for segment in segments:
            try:
                segment.close()
            except Exception:
                pass

    try:
        for _ in range(args.workers):
            segment = shared_memory.SharedMemory(create=True, size=segment_bytes)
            segment.unlink()
            segments.append(segment)

        for worker_id in range(args.workers):
            task_queue = ctx.Queue()
            process = ctx.Process(
                target=worker_main,
                name=f"tensor-prefetch-{worker_id}",
                args=(worker_id, segments[worker_id], slot_bytes, task_queue, results),
            )
            process.start()
            task_queues.append(task_queue)
            processes.append(process)

        batches_required = math.ceil(args.required_items / args.batch_size)
        if args.mode == "finite" and batches_required < args.workers * args.prefetch_factor:
            raise SystemExit("finite recipe must exercise every prefetch slot")

        next_sequence = [worker_id for worker_id in range(args.workers)]

        def batch_for(sequence):
            start = sequence * args.batch_size
            return [records[(start + offset) % len(records)] for offset in range(args.batch_size)]

        submitted = 0
        for worker_id in range(args.workers):
            for slot in range(args.prefetch_factor):
                sequence = next_sequence[worker_id]
                next_sequence[worker_id] += args.workers
                if args.mode == "finite" and submitted >= batches_required:
                    break
                task_queues[worker_id].put(
                    {"slot": slot, "sequence": sequence, "records": batch_for(sequence)}
                )
                submitted += 1

        initial_expected = min(batches_required, args.workers * args.prefetch_factor)
        pending = []
        deadline = time.monotonic() + 30
        while len(pending) < initial_expected and not stopping:
            try:
                pending.append(results.get(timeout=0.2))
            except queue.Empty:
                dead = [process.exitcode for process in processes if process.exitcode is not None]
                if any(code == -signal.SIGBUS for code in dead):
                    raise SharedMemoryPressure("worker_sigbus")
                if dead:
                    raise RuntimeError(f"prefetch worker exited before high-water mark: {dead}")
                if time.monotonic() > deadline:
                    raise RuntimeError("prefetch high-water deadline expired")

        allocated = sum(os.fstat(segment._fd).st_blocks * 512 for segment in segments)
        if allocated < int(target * 0.90):
            raise RuntimeError(f"prefetch tensors were not fully committed: {allocated}/{target}")

        output_file = output_dir / ("embeddings.jsonl" if args.mode == "finite" else "batches.jsonl")
        output_handle = output_file.open("w", encoding="utf-8")
        finite_rows = []
        completed_batches = 0
        completed_items = 0
        last_checksum = ""
        ready = False

        def write_state():
            if not args.state_file:
                return
            objects = []
            for segment in segments:
                stat = os.fstat(segment._fd)
                objects.append(
                    {
                        "device": stat.st_dev,
                        "inode": stat.st_ino,
                        "size": stat.st_size,
                        "allocated_bytes": stat.st_blocks * 512,
                    }
                )
            atomic_json(
                args.state_file,
                {
                    "ready": int(ready),
                    "pid": os.getpid(),
                    "start_time": process_start_time(os.getpid()),
                    "worker_pids": [process.pid for process in processes],
                    "recipe_hash": recipe_hash,
                    "recipe": recipe,
                    "progress_batches": completed_batches,
                    "progress_items": completed_items,
                    "last_batch_checksum": last_checksum,
                    "names_unlinked": True,
                    "shm_objects": objects,
                    "allocated_bytes": sum(item["allocated_bytes"] for item in objects),
                    "output_file": str(output_file),
                    "updated_at": time.time(),
                },
            )

        while not stopping:
            if pending:
                item = pending.pop(0)
            else:
                try:
                    item = results.get(timeout=0.25)
                except queue.Empty:
                    dead = [process.exitcode for process in processes if process.exitcode is not None]
                    if any(code == -signal.SIGBUS for code in dead):
                        raise SharedMemoryPressure("worker_sigbus")
                    if dead:
                        raise RuntimeError(f"prefetch worker exited unexpectedly: {dead}")
                    continue

            for record in item["records"]:
                if args.mode == "finite" and completed_items >= args.required_items:
                    break
                if args.mode == "finite":
                    finite_rows.append((item["sequence"], len(finite_rows), record))
                else:
                    output_handle.write(json.dumps(record, sort_keys=True) + "\n")
                completed_items += 1
            if args.mode == "continuous":
                output_handle.flush()
                os.fsync(output_handle.fileno())
            completed_batches += 1
            last_checksum = item["tensor_checksum"]
            ready = True
            write_state()

            if args.mode == "finite" and completed_items >= args.required_items:
                break

            worker_id = item["worker"]
            sequence = next_sequence[worker_id]
            next_sequence[worker_id] += args.workers
            task_queues[worker_id].put(
                {"slot": item["slot"], "sequence": sequence, "records": batch_for(sequence)}
            )
            if args.consumer_delay:
                time.sleep(args.consumer_delay)

        if args.mode == "finite" and completed_items != args.required_items:
            raise RuntimeError(f"incomplete embedding export: {completed_items}/{args.required_items}")

        if args.mode == "finite":
            finite_rows.sort(key=lambda item: (item[0], item[1]))
            for _sequence, _arrival, record in finite_rows:
                output_handle.write(json.dumps(record, sort_keys=True) + "\n")
            output_handle.flush()
            os.fsync(output_handle.fileno())
        output_handle.close()

        if args.mode == "finite":
            manifest = {
                "complete": True,
                "namespace": args.namespace,
                "items": completed_items,
                "output_sha256": file_sha256(output_file),
                "recipe": recipe,
                "recipe_hash": recipe_hash,
                "shared_memory": {
                    "transport": "multiprocessing_posix_shm_prefetch",
                    "names_unlinked": True,
                    "segments": len(segments),
                    "allocated_high_water_bytes": allocated,
                },
            }
            atomic_json(output_dir / "manifest.json", manifest)
            print(
                f"PIPELINE_OK=1 items={completed_items} workers={args.workers} "
                f"prefetch={args.prefetch_factor} allocated={allocated}"
            )
        return 0
    except SharedMemoryPressure as error:
        print(
            f"PIPELINE_SHM_ERROR=1 kind={error} free_bytes={mount_free_bytes()} "
            f"target_bytes={target}",
            flush=True,
        )
        return 75
    except OSError as error:
        if error.errno in (28, 12):
            print(
                f"PIPELINE_SHM_ERROR=1 kind=errno_{error.errno} free_bytes={mount_free_bytes()} "
                f"target_bytes={target}",
                flush=True,
            )
            return 75
        raise
    finally:
        cleanup()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"PIPELINE_ERROR=1 type={type(error).__name__} detail={error}", file=sys.stderr)
        raise
