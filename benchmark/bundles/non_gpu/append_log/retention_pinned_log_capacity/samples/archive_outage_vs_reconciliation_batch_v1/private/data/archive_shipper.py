#!/usr/bin/env python3
import argparse
import hashlib
import os
import pathlib
import signal
import sys
import time

sys.path.insert(0, "/opt/payment-journal/lib")
from bounded_journal import Journal, atomic_json  # noqa: E402


running = True


def stop(_signum, _frame):
    global running
    running = False


def copy_durable(source_bytes, target):
    target = pathlib.Path(target)
    temporary = target.with_name(target.name + f".tmp.{os.getpid()}")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o660)
    try:
        os.write(fd, source_bytes)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, target)
    directory_fd = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def main():
    parser = argparse.ArgumentParser(description="Payment journal archival shipper")
    parser.add_argument("--store", required=True)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--progress", required=True)
    args = parser.parse_args()
    archive = pathlib.Path(args.archive)
    archive.mkdir(parents=True, exist_ok=True)
    journal = Journal(args.store)
    copied = 0

    while running:
        inventory = journal.inventory()
        pending = []
        for segment in inventory["segments"]:
            if not segment["sealed"] or not segment["retention_pinned"]:
                continue
            target = archive / f"{segment['segment_id']}.archive"
            logical = journal.logical_bytes(segment)
            digest = hashlib.sha256(logical).hexdigest()
            if digest != segment["sha256"]:
                raise RuntimeError(f"sealed digest mismatch for {segment['segment_id']}")
            if not target.exists():
                copy_durable(logical, target)
                copied += 1
            if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                raise RuntimeError(f"archive copy mismatch for {segment['segment_id']}")
            pending.append(
                {
                    "segment_id": segment["segment_id"],
                    "sha256": digest,
                    "archive_copy": str(target),
                    "used_bytes": segment["used_bytes"],
                }
            )
        atomic_json(
            args.progress,
            {
                "pid": os.getpid(),
                "phase": "awaiting_remote_acknowledgement",
                "copies_created": copied,
                "pending_count": len(pending),
                "pending": pending,
                "manifest_generation": inventory["manifest_generation"],
                "ack_generation": inventory["ack_generation"],
                "updated_unix_ns": time.time_ns(),
            },
            0o644,
        )
        time.sleep(0.2)
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    raise SystemExit(main())
