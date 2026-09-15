#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import signal
import time
import zlib


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
header = (args.header + "\nformat=wal-v3\n").encode().ljust(4096, b"\0")
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
    lsn = 0x17000000 + sequence * 4096
    body = f"lsn={lsn:016x} batch={sequence:08d}".encode()
    crc = zlib.crc32(body)
    record = body + f" crc={crc:08x}\n".encode()
    record = record.ljust(4096, bytes([sequence % 251 + 1]))
    offset = 4096 + ((sequence - 1) % 255) * 4096
    os.pwrite(fd, record, offset)
    os.fsync(fd)
    stat = os.fstat(fd)
    atomic_json(
        args.progress,
        {
            "pid": os.getpid(),
            "started_ns": started,
            "sequence": sequence,
            "durable_lsn": f"{lsn:016x}",
            "record_crc32": f"{crc:08x}",
            "reserve_bytes": args.reserve_bytes,
            "device": stat.st_dev,
            "inode": stat.st_ino,
            "header_sha256": hashlib.sha256(header).hexdigest(),
            "state": "streaming",
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

