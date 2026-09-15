#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import signal
import time


def atomic_json(path, payload):
    temporary = path + ".next"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


parser = argparse.ArgumentParser()
parser.add_argument("--file", required=True)
parser.add_argument("--progress", required=True)
parser.add_argument("--pid-file", required=True)
parser.add_argument("--reserve-bytes", required=True, type=int)
parser.add_argument("--header", required=True)
args = parser.parse_args()
running = True


def stop(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
os.makedirs(os.path.dirname(args.file), exist_ok=True)
fd = os.open(args.file, os.O_CREAT | os.O_RDWR, 0o640)
os.posix_fallocate(fd, 0, args.reserve_bytes)
header = (args.header + "\nlayout=zero3-fp32\n").encode().ljust(4096, b"\0")
os.pwrite(fd, header, 0)
os.fsync(fd)
with open(args.pid_file, "w", encoding="ascii") as handle:
    handle.write(f"{os.getpid()}\n")
    handle.flush()
    os.fsync(handle.fileno())

started = time.time_ns()
sequence = 0
while running:
    sequence += 1
    tensor_name = f"encoder.layer.{(sequence - 1) % 24}.mlp.weight"
    digest = hashlib.sha256(f"r17:{tensor_name}:{sequence}".encode()).digest()
    stripe = (digest * (262144 // len(digest))).ljust(262144, b"\0")
    offset = 4096 + ((sequence - 1) % 6) * 262144
    os.pwrite(fd, stripe, offset)
    os.fsync(fd)
    stat = os.fstat(fd)
    atomic_json(
        args.progress,
        {
            "pid": os.getpid(),
            "started_ns": started,
            "sequence": sequence,
            "tensor": tensor_name,
            "stripe_sha256": hashlib.sha256(stripe).hexdigest(),
            "serialized_bytes": min(sequence, 6) * len(stripe),
            "reserve_bytes": args.reserve_bytes,
            "device": stat.st_dev,
            "inode": stat.st_ino,
            "header_sha256": hashlib.sha256(header).hexdigest(),
            "state": "serializing",
        },
    )
    time.sleep(0.15)

atomic_json(
    args.progress,
    {
        "pid": os.getpid(),
        "started_ns": started,
        "sequence": sequence,
        "reserve_bytes": args.reserve_bytes,
        "state": "closed_cleanly",
    },
)
os.close(fd)

