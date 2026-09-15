#!/usr/bin/env python3
"""Build a bounded microscopy mosaic with shared-memory tile staging."""

import argparse
import hashlib
import json
import pathlib
import sys
import time
import zlib
from multiprocessing import Process, Queue
from multiprocessing.shared_memory import SharedMemory

from tile_ring import HEADER_BYTES, SLOT_HEADER, commit_shared_memory, layout, payload_for


def worker(shm_name, slots, item_bytes, tasks: Queue, output: pathlib.Path):
    shm = SharedMemory(name=shm_name)
    stride, _ = layout(len(shm.buf), slots)
    records = []
    try:
        while True:
            item = tasks.get()
            if item is None:
                break
            sequence, slot, source = item
            offset = HEADER_BYTES + slot * stride
            actual, length, checksum = SLOT_HEADER.unpack_from(shm.buf, offset)
            payload = bytes(shm.buf[offset + SLOT_HEADER.size : offset + SLOT_HEADER.size + length])
            if actual != sequence or zlib.crc32(payload) & 0xFFFFFFFF != checksum:
                raise RuntimeError(f"corrupt microscopy tile {sequence}")
            records.append(
                {
                    "tile": source["tile"],
                    "row": source["row"],
                    "column": source["column"],
                    "channel": source["channel"],
                    "exposure_us": source["exposure_us"],
                    "tile_sha256": hashlib.sha256(payload).hexdigest(),
                    "focus_score": (sum(payload[:1024]) + sequence * 29) % 8192,
                }
            )
        output.write_text("\n".join(json.dumps(item, sort_keys=True) for item in records) + ("\n" if records else ""))
    finally:
        shm.close()


def output_complete(output: pathlib.Path, expected_items: int, expected_workers: int) -> bool:
    try:
        manifest = json.loads((output / "manifest.json").read_text())
        index = json.loads((output / "tile_index.json").read_text())
        dimensions = json.loads((output / "dimensions.json").read_text())
        return (
            manifest.get("complete") is True
            and manifest.get("tiles") == expected_items
            and manifest.get("workers") == expected_workers
            and manifest.get("ring_name", "").startswith("b_tile_")
            and len(index) == expected_items
            and len({item["tile"] for item in index}) == expected_items
            and dimensions == {"rows": 4, "columns": 5, "tiles": expected_items}
            and (output / "mosaic.pgm").read_bytes().startswith(b"P5\n5 4\n255\n")
            and (output / "mosaic.pgm").stat().st_size == len(b"P5\n5 4\n255\n") + expected_items
        )
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return False


def run(args) -> int:
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    source_items = [json.loads(line) for line in pathlib.Path(args.input).read_text().splitlines() if line]
    if len(source_items) < args.items:
        print("B_OUTPUT_ERROR=insufficient_microscopy_tiles", file=sys.stderr)
        return 77
    ring_bytes = int(args.ring_bytes)
    stride, item_bytes = layout(ring_bytes, args.slots)
    seed = pathlib.Path(args.input).read_bytes()
    shm = None
    workers = []
    try:
        try:
            shm = SharedMemory(name=args.ring_name, create=True, size=ring_bytes)
            commit_shared_memory(shm, ring_bytes)
        except OSError as exc:
            print(f"B_RESOURCE_ERROR=shared_memory errno={exc.errno} bytes={ring_bytes}", file=sys.stderr)
            return 75
        tasks = Queue(maxsize=max(2, args.workers * 2))
        part_paths = []
        for index in range(args.workers):
            part = output / f"stitch-worker-{index}.jsonl"
            part_paths.append(part)
            process = Process(
                target=worker,
                name=f"mosaic-worker-{index}",
                args=(args.ring_name, args.slots, item_bytes, tasks, part),
            )
            process.start()
            workers.append(process)
        # Normal fixed-geometry initialization leaves the committed tile ring
        # and all stitch workers attached long enough for operational metrics.
        time.sleep(0.4)
        for sequence in range(1, args.items + 1):
            slot = (sequence - 1) % args.slots
            offset = HEADER_BYTES + slot * stride
            payload = payload_for(seed, sequence, item_bytes)
            checksum = zlib.crc32(payload) & 0xFFFFFFFF
            shm.buf[offset + SLOT_HEADER.size : offset + SLOT_HEADER.size + item_bytes] = payload
            SLOT_HEADER.pack_into(shm.buf, offset, sequence, item_bytes, checksum)
            tasks.put((sequence, slot, source_items[sequence - 1]))
        for _ in workers:
            tasks.put(None)
        for process in workers:
            process.join(timeout=20)
            if process.is_alive() or process.exitcode != 0:
                print(f"B_WORKER_ERROR=1 pid={process.pid} exit={process.exitcode}", file=sys.stderr)
                return 76
        records = []
        for part in part_paths:
            for line in part.read_text().splitlines() if part.exists() else []:
                if line:
                    records.append(json.loads(line))
        records.sort(key=lambda item: item["tile"])
        index_path = output / "tile_index.json"
        index_path.write_text(json.dumps(records, indent=2) + "\n")
        dimensions = {"rows": 4, "columns": 5, "tiles": len(records)}
        (output / "dimensions.json").write_text(json.dumps(dimensions, indent=2) + "\n")
        pixels = bytes((item["focus_score"] % 256 for item in records))
        pixels = (pixels + b"\0" * args.items)[: args.items]
        (output / "mosaic.pgm").write_bytes(b"P5\n5 4\n255\n" + pixels)
        index_hash = hashlib.sha256(index_path.read_bytes()).hexdigest()
        mosaic_hash = hashlib.sha256((output / "mosaic.pgm").read_bytes()).hexdigest()
        (output / "manifest.json").write_text(
            json.dumps(
                {
                    "complete": len(records) == args.items,
                    "tiles": len(records),
                    "workers": args.workers,
                    "ring_name": args.ring_name,
                    "tile_index_sha256": index_hash,
                    "mosaic_sha256": mosaic_hash,
                },
                indent=2,
            )
            + "\n"
        )
        if not output_complete(output, args.items, args.workers):
            print("B_OUTPUT_ERROR=semantic_verification_failed", file=sys.stderr)
            return 77
        print(f"B_COMPLETE=1 tiles={args.items} workers={args.workers} ring_bytes={ring_bytes}")
        return 0
    finally:
        for process in workers:
            if process.is_alive():
                process.terminate()
        if shm is not None:
            try:
                shm.close()
            finally:
                try:
                    shm.unlink()
                except FileNotFoundError:
                    pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--ring-name", required=True)
    parser.add_argument("--ring-bytes", required=True, type=int)
    parser.add_argument("--slots", required=True, type=int)
    parser.add_argument("--workers", required=True, type=int)
    parser.add_argument("--items", required=True, type=int)
    return run(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
