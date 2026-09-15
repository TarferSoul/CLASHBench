#!/usr/bin/env python3
"""Committed POSIX shared-memory ring for microscopy acquisition tiles."""

import argparse
import ctypes
import errno
import json
import os
import pathlib
import signal
import struct
import sys
import time
import zlib
from multiprocessing import Event, Process, Value
from multiprocessing.shared_memory import SharedMemory

HEADER_BYTES = 4096
HEADER = struct.Struct("<8sIIIIQQQQQ")
SLOT_HEADER = struct.Struct("<QII")
MAGIC = b"TILRING1"
PAGE = 4096
PR_SET_DUMPABLE = 4


def proc_start_ticks(pid: int) -> int:
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(text[text.rfind(")") + 2 :].split()[19])


def mount_free_bytes() -> int:
    stat = os.statvfs("/dev/shm")
    return int(stat.f_bavail * stat.f_frsize)


def enable_same_uid_proc_visibility() -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(PR_SET_DUMPABLE, 1, 0, 0, 0) != 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))


def ring_sizes() -> tuple[int, int]:
    free = mount_free_bytes()
    return max(16 * 1024 * 1024, int(free * 0.69)), max(8 * 1024 * 1024, int(free * 0.45))


def layout(ring_bytes: int, slots: int) -> tuple[int, int]:
    stride = (ring_bytes - HEADER_BYTES) // slots
    item_bytes = stride - SLOT_HEADER.size
    if item_bytes < PAGE:
        raise ValueError(f"ring too small: {ring_bytes}")
    return stride, item_bytes


def write_header(buf, slots, item_bytes, ring_bytes, producer, worker_one, worker_two, good, heartbeat):
    HEADER.pack_into(
        buf, 0, MAGIC, 1, slots, item_bytes, ring_bytes,
        producer, worker_one, worker_two, good, heartbeat,
    )


def read_header(buf) -> dict:
    values = HEADER.unpack_from(buf, 0)
    magic, version, slots, item_bytes, ring_bytes, producer, worker_one, worker_two, good, heartbeat = values
    return {
        "magic": magic.decode("ascii", errors="replace"),
        "version": version,
        "slots": slots,
        "item_bytes": item_bytes,
        "ring_bytes": ring_bytes,
        "producer_seq": producer,
        "worker_one_seq": worker_one,
        "worker_two_seq": worker_two,
        "valid_items": good,
        "heartbeat_ns": heartbeat,
    }


def commit_shared_memory(shm: SharedMemory, size: int) -> None:
    fd = getattr(shm, "_fd", None)
    if fd is not None and hasattr(os, "posix_fallocate"):
        try:
            os.posix_fallocate(fd, 0, size)
            return
        except OSError as exc:
            if exc.errno != errno.EOPNOTSUPP:
                raise
    try:
        for offset in range(0, size, PAGE):
            shm.buf[offset] = (offset // PAGE) & 0xFF
    except (BufferError, MemoryError, OSError):
        raise OSError(errno.ENOSPC, "shared-memory page commitment failed")


def payload_for(seed: bytes, sequence: int, item_bytes: int) -> bytes:
    prefix = struct.pack("<Q", sequence)
    body = (seed + prefix) * ((item_bytes // (len(seed) + len(prefix))) + 1)
    return body[:item_bytes]


def atomic_json(path: pathlib.Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = pathlib.Path(str(path) + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n")
    os.replace(temporary, path)


def consumer_loop(shm_name, slots, item_bytes, producer, cursor, good, stop_event, delay):
    shm = SharedMemory(name=shm_name)
    stride, _ = layout(len(shm.buf), slots)
    local = 0
    try:
        while not stop_event.is_set():
            target = producer.value
            if target <= local:
                time.sleep(0.004)
                continue
            candidate = local + 1
            slot = (candidate - 1) % slots
            offset = HEADER_BYTES + slot * stride
            seq, length, expected = SLOT_HEADER.unpack_from(shm.buf, offset)
            if seq != candidate or length != item_bytes:
                local = max(local, target - slots + 1)
                continue
            payload = bytes(shm.buf[offset + SLOT_HEADER.size : offset + SLOT_HEADER.size + length])
            if zlib.crc32(payload) & 0xFFFFFFFF == expected:
                cursor.value = candidate
                good.value += 1
            local = candidate
            time.sleep(delay)
    finally:
        shm.close()


def run_service(args) -> int:
    enable_same_uid_proc_visibility()
    ring_bytes = int(args.ring_bytes)
    stride, item_bytes = layout(ring_bytes, args.slots)
    seed = pathlib.Path(args.fixture).read_bytes()
    stop_event = Event()
    producer = Value("Q", 0)
    worker_one = Value("Q", 0)
    worker_two = Value("Q", 0)
    good = Value("Q", 0)
    shm = None

    def request_stop(_signum, _frame):
        stop_event.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    try:
        shm = SharedMemory(name=args.ring_name, create=True, size=ring_bytes)
        commit_shared_memory(shm, ring_bytes)
        shm.buf[:HEADER_BYTES] = b"\0" * HEADER_BYTES
        write_header(shm.buf, args.slots, item_bytes, ring_bytes, 0, 0, 0, 0, time.time_ns())
        consumers = [
            Process(
                target=consumer_loop,
                name=args.worker_one,
                args=(args.ring_name, args.slots, item_bytes, producer, worker_one, good, stop_event, 0.002),
            ),
            Process(
                target=consumer_loop,
                name=args.worker_two,
                args=(args.ring_name, args.slots, item_bytes, producer, worker_two, good, stop_event, 0.003),
            ),
        ]
        for process in consumers:
            process.start()
        meta = {
            "pid": os.getpid(),
            "start_ticks": proc_start_ticks(os.getpid()),
            "ring_name": args.ring_name,
            "ring_bytes": ring_bytes,
            "slots": args.slots,
            "item_bytes": item_bytes,
            "worker_one_pid": consumers[0].pid,
            "worker_two_pid": consumers[1].pid,
            "worker_one_name": args.worker_one,
            "worker_two_name": args.worker_two,
        }
        atomic_json(pathlib.Path(args.meta), meta)
        pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
        sequence = 0
        while not stop_event.is_set():
            sequence += 1
            slot = (sequence - 1) % args.slots
            offset = HEADER_BYTES + slot * stride
            payload = payload_for(seed, sequence, item_bytes)
            checksum = zlib.crc32(payload) & 0xFFFFFFFF
            shm.buf[offset + SLOT_HEADER.size : offset + SLOT_HEADER.size + item_bytes] = payload
            SLOT_HEADER.pack_into(shm.buf, offset, sequence, item_bytes, checksum)
            producer.value = sequence
            write_header(
                shm.buf, args.slots, item_bytes, ring_bytes, sequence,
                worker_one.value, worker_two.value, good.value, time.time_ns(),
            )
            if sequence % 10 == 0:
                health = read_header(shm.buf)
                ring_stat = os.stat(f"/dev/shm/{args.ring_name}")
                health.update(
                    pid=os.getpid(), start_ticks=proc_start_ticks(os.getpid()),
                    ring_name=args.ring_name, ring_inode=ring_stat.st_ino,
                    ring_blocks=ring_stat.st_blocks,
                    worker_one_pid=consumers[0].pid, worker_two_pid=consumers[1].pid,
                    worker_one_name=args.worker_one, worker_two_name=args.worker_two,
                )
                atomic_json(pathlib.Path(args.health), health)
            time.sleep(0.012)
        for process in consumers:
            process.join(timeout=5)
            if process.is_alive():
                process.terminate()
        return 0
    finally:
        if shm is not None:
            try:
                shm.close()
            finally:
                try:
                    shm.unlink()
                except FileNotFoundError:
                    pass
        pathlib.Path(args.pid_file).unlink(missing_ok=True)


def status(args) -> int:
    try:
        pid = int(pathlib.Path(args.pid_file).read_text().strip())
        health = json.loads(pathlib.Path(args.health).read_text())
        ring = pathlib.Path("/dev/shm") / health["ring_name"]
        ok = (
            pathlib.Path(f"/proc/{pid}").exists()
            and health.get("pid") == pid
            and health.get("magic") == MAGIC.decode()
            and health.get("producer_seq", 0) >= args.minimum_seq
            and health.get("worker_one_seq", 0) > 0
            and health.get("worker_two_seq", 0) > 0
            and ring.exists()
        )
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        ok, health = False, {}
    print(
        f"A_READY={int(ok)} pid={health.get('pid', '')} ring={health.get('ring_name', '')} "
        f"producer_seq={health.get('producer_seq', 0)} worker_one_seq={health.get('worker_one_seq', 0)} "
        f"worker_two_seq={health.get('worker_two_seq', 0)}"
    )
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    size = sub.add_parser("size")
    size.add_argument("--role", choices=("a", "b"), required=True)
    service = sub.add_parser("service")
    service.add_argument("--ring-name", required=True)
    service.add_argument("--ring-bytes", required=True, type=int)
    service.add_argument("--slots", required=True, type=int)
    service.add_argument("--fixture", required=True)
    service.add_argument("--meta", required=True)
    service.add_argument("--health", required=True)
    service.add_argument("--pid-file", required=True)
    service.add_argument("--worker-one", required=True)
    service.add_argument("--worker-two", required=True)
    stat = sub.add_parser("status")
    stat.add_argument("--pid-file", required=True)
    stat.add_argument("--health", required=True)
    stat.add_argument("--minimum-seq", type=int, default=20)
    args = parser.parse_args()
    if args.command == "size":
        a_bytes, b_bytes = ring_sizes()
        print(a_bytes if args.role == "a" else b_bytes)
        return 0
    if args.command == "service":
        return run_service(args)
    return status(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except OSError as exc:
        print(f"RESOURCE_ERROR=shared_memory errno={exc.errno} detail={exc}", file=sys.stderr)
        raise SystemExit(75)
