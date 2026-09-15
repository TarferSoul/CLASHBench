#!/usr/bin/env python3
"""Maintain verified compacted packs for independent artifact repositories."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


MIB = 1024 * 1024
STOP = False


def request_stop(_signum, _frame):
    global STOP
    STOP = True


def atomic_json(path, value):
    path = Path(path)
    temp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    with temp.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp, path)
    directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def run_checked(command):
    completed = subprocess.run(command, text=True, capture_output=True)
    if completed.returncode != 0:
        raise RuntimeError(
            f"command failed rc={completed.returncode}: {' '.join(command)}: "
            f"{completed.stderr[-800:]}"
        )


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb", buffering=0) as handle:
        while True:
            block = handle.read(4 * MIB)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def process_start_time(pid):
    return int(Path(f"/proc/{pid}/stat").read_text().split()[21])


def write_worker_state(runtime, repository, phase, sequence, cycle, **extra):
    payload = {
        "repository": repository,
        "pid": os.getpid(),
        "start_time": process_start_time(os.getpid()),
        "phase": phase,
        "sequence": sequence,
        "completed_cycles": cycle,
        "updated_at": time.time(),
    }
    payload.update(extra)
    atomic_json(Path(runtime) / f"worker_{repository:02d}.json", payload)


def worker(args):
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    repository_root = Path(args.data_root) / f"repository_{args.repository:02d}"
    source_root = repository_root / "source"
    pack_root = repository_root / "packs"
    cycle_root = repository_root / "cycles"
    pack_root.mkdir(parents=True, exist_ok=True)
    cycle_root.mkdir(parents=True, exist_ok=True)
    part_bytes = args.part_mib * MIB
    block_bytes = args.block_mib * MIB
    blocks_per_part = part_bytes // block_bytes
    parts = [source_root / f"segment_{index:02d}.bin" for index in range(1, args.parts + 1)]
    total_bytes = part_bytes * args.parts
    sequence = 0
    cycle = 0
    write_worker_state(args.runtime_root, args.repository, "starting", sequence, cycle)

    while not STOP:
        cycle += 1
        slot = cycle % 2
        target = pack_root / f"compacted_slot_{slot}.pack"
        temporary = pack_root / f".compacted_slot_{slot}.tmp.{os.getpid()}"
        started = time.monotonic()
        try:
            with temporary.open("wb") as handle:
                handle.truncate(total_bytes)
                handle.flush()
                os.fsync(handle.fileno())
            for index, part in enumerate(parts):
                if STOP:
                    break
                sequence += 1
                write_worker_state(
                    args.runtime_root, args.repository, "copying", sequence, cycle - 1,
                    active_cycle=cycle, copied_parts=index, bytes_written=index * part_bytes,
                )
                run_checked([
                    "dd", f"if={part}", f"of={temporary}", f"bs={block_bytes}",
                    "iflag=direct", "oflag=direct", "conv=notrunc",
                    f"count={blocks_per_part}", f"seek={index * blocks_per_part}", "status=none",
                ])
            if STOP:
                break
            for index, part in enumerate(parts):
                sequence += 1
                write_worker_state(
                    args.runtime_root, args.repository, "verifying", sequence, cycle - 1,
                    active_cycle=cycle, copied_parts=args.parts, validated_parts=index,
                    bytes_written=total_bytes,
                )
                run_checked([
                    "cmp", "--silent", f"--bytes={part_bytes}",
                    f"--ignore-initial=0:{index * part_bytes}", str(part), str(temporary),
                ])
            pack_fd = os.open(temporary, os.O_RDONLY)
            try:
                os.fsync(pack_fd)
            finally:
                os.close(pack_fd)
            digest = sha256(temporary)
            os.replace(temporary, target)
            directory_fd = os.open(pack_root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            record = {
                "repository": args.repository,
                "cycle": cycle,
                "slot": slot,
                "pack": str(target),
                "pack_bytes": total_bytes,
                "pack_sha256": digest,
                "validated_parts": args.parts,
                "durable_publish": True,
                "elapsed_seconds": time.monotonic() - started,
                "published_at": time.time(),
            }
            cycle_record = cycle_root / f"cycle_{cycle:08d}.json"
            atomic_json(cycle_record, record)
            record["record_sha256"] = sha256(cycle_record)
            atomic_json(repository_root / "latest.json", record)
            sequence += 1
            write_worker_state(
                args.runtime_root, args.repository, "published", sequence, cycle,
                active_cycle=cycle, copied_parts=args.parts, validated_parts=args.parts,
                bytes_written=total_bytes, pack=str(target), pack_sha256=digest,
            )
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
    write_worker_state(args.runtime_root, args.repository, "stopped", sequence, cycle)
    return 0


def supervisor(args):
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    runtime = Path(args.runtime_root)
    runtime.mkdir(parents=True, exist_ok=True)
    children = []
    for repository in range(1, args.repositories + 1):
        command = [
            sys.executable, str(Path(__file__).resolve()), "--worker",
            "--data-root", args.data_root, "--runtime-root", args.runtime_root,
            "--repository", str(repository), "--parts", str(args.parts),
            "--part-mib", str(args.part_mib), "--block-mib", str(args.block_mib),
        ]
        children.append(subprocess.Popen(command))
    service = {
        "service": "artifact-pack-maintenance",
        "pid": os.getpid(),
        "start_time": process_start_time(os.getpid()),
        "pgid": os.getpgrp(),
        "worker_pids": [child.pid for child in children],
        "repositories": args.repositories,
        "parts_per_repository": args.parts,
        "part_mib": args.part_mib,
        "block_mib": args.block_mib,
        "started_at": time.time(),
    }
    atomic_json(runtime / "service.json", service)
    (runtime / "service.pid").write_text(f"{os.getpid()}\n", encoding="ascii")
    while not STOP:
        exited = [child for child in children if child.poll() is not None]
        if exited:
            STOP_REASON = ",".join(str(child.pid) for child in exited)
            atomic_json(runtime / "failure.json", {"exited_workers": STOP_REASON, "at": time.time()})
            for child in children:
                if child.poll() is None:
                    child.terminate()
            for child in children:
                child.wait()
            return 2
        time.sleep(0.1)
    for child in children:
        if child.poll() is None:
            child.terminate()
    deadline = time.monotonic() + 20
    for child in children:
        remaining = max(0.1, deadline - time.monotonic())
        try:
            child.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
    return 0


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--data-root", required=True)
    parser.add_argument("--runtime-root", required=True)
    parser.add_argument("--repositories", type=int, default=0)
    parser.add_argument("--repository", type=int, default=0)
    parser.add_argument("--parts", type=int, required=True)
    parser.add_argument("--part-mib", type=int, required=True)
    parser.add_argument("--block-mib", type=int, required=True)
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    if arguments.part_mib % arguments.block_mib:
        raise SystemExit("part size must align to block size")
    sys.exit(worker(arguments) if arguments.worker else supervisor(arguments))
