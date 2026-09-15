#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import re
import signal
import struct
import sys
import time


MAX_FRAME_BYTES = 1024 * 1024


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def load_records(path):
    records = []
    seen = set()
    for number, line in enumerate(pathlib.Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict) or not isinstance(value.get("event_id"), str):
            raise ValueError(f"line {number}: object with string event_id required")
        if value["event_id"] in seen:
            raise ValueError(f"line {number}: duplicate event_id")
        digest = value.get("statement_sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError(f"line {number}: lowercase statement_sha256 required")
        seen.add(value["event_id"])
        records.append(value)
    if not records:
        raise ValueError("input contains no records")
    return records


def atomic_json(path, value, mode=None):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + f".tmp.{os.getpid()}")
    with temporary.open("w", encoding="utf-8") as handle:
        handle.write(json.dumps(value, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    if mode is not None:
        os.chmod(temporary, mode)
    os.replace(temporary, target)
    directory_fd = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def read_frames(path):
    frames = []
    offset = 0
    with open(path, "rb") as handle:
        while True:
            header = handle.read(4)
            if not header:
                return frames, offset
            if len(header) != 4:
                raise ValueError(f"truncated frame header at offset {offset}")
            length = struct.unpack(">I", header)[0]
            if not 1 <= length <= MAX_FRAME_BYTES:
                raise ValueError(f"invalid frame length {length} at offset {offset}")
            payload = handle.read(length)
            if len(payload) != length:
                raise ValueError(f"truncated frame payload at offset {offset}")
            frames.append(json.loads(payload.decode("utf-8")))
            offset += 4 + length


def main():
    parser = argparse.ArgumentParser(description="Append one durable binary transaction to the registry provenance ledger")
    parser.add_argument("--log", required=True)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--transaction", required=True)
    parser.add_argument("--commit-metadata", required=True)
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--record-delay", type=float, default=0.0)
    parser.add_argument("--progress")
    parser.add_argument("--actor", default="provenance-ledger-client")
    args = parser.parse_args()

    pathlib.Path(args.log).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.lock).parent.mkdir(parents=True, exist_ok=True)
    lock_handle = open(args.lock, "a+", encoding="utf-8")
    deadline = time.monotonic() + args.timeout
    while True:
        try:
            fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                print(f"LOCK_BUSY transaction={args.transaction} lock={args.lock}", file=sys.stderr)
                return 75
            time.sleep(0.05)

    records = load_records(args.input)
    payload_text = "\n".join(canonical(record) for record in records) + "\n"
    payload_digest = hashlib.sha256(payload_text.encode()).hexdigest()

    with open(args.log, "a+b", buffering=0) as log_handle:
        log_stat = os.fstat(log_handle.fileno())
        lock_stat = os.fstat(lock_handle.fileno())
        frames, parsed_bytes = read_frames(args.log)
        if parsed_bytes != log_stat.st_size:
            raise ValueError("ledger parser did not consume the complete file")
        sequences = [int(frame["seq"]) for frame in frames]
        if sequences != list(range(1, len(sequences) + 1)):
            raise ValueError("existing ledger sequence is not contiguous")
        sequence = len(sequences) + 1
        start_offset = os.lseek(log_handle.fileno(), 0, os.SEEK_END)
        appended = 0

        def write_frame(frame):
            nonlocal sequence
            complete = {"seq": sequence, **frame}
            encoded = canonical(complete).encode()
            if len(encoded) > MAX_FRAME_BYTES:
                raise ValueError("frame exceeds maximum size")
            os.write(log_handle.fileno(), struct.pack(">I", len(encoded)) + encoded)
            sequence += 1

        def publish_progress(phase):
            if args.progress:
                atomic_json(args.progress, {
                    "pid": os.getpid(),
                    "transaction": args.transaction,
                    "phase": phase,
                    "validated_records": len(records),
                    "appended_records": appended,
                    "last_sequence": sequence - 1,
                    "last_end_offset": os.lseek(log_handle.fileno(), 0, os.SEEK_END),
                    "log_device": log_stat.st_dev,
                    "log_inode": log_stat.st_ino,
                    "lock_device": lock_stat.st_dev,
                    "lock_inode": lock_stat.st_ino,
                    "framing": "be32-json-v1",
                    "updated_unix_ns": time.time_ns(),
                }, 0o644)

        write_frame({
            "frame": "BEGIN",
            "transaction": args.transaction,
            "actor": args.actor,
            "record_count": len(records),
            "payload_sha256": payload_digest,
        })
        os.fsync(log_handle.fileno())
        publish_progress("appending")
        for record in records:
            write_frame({"frame": "ENTRY", "transaction": args.transaction, "payload": record})
            appended += 1
            if appended % 16 == 0:
                os.fsync(log_handle.fileno())
            publish_progress("appending")
            if args.record_delay:
                time.sleep(args.record_delay)

        write_frame({
            "frame": "COMMIT",
            "transaction": args.transaction,
            "record_count": len(records),
            "payload_sha256": payload_digest,
        })
        os.fsync(log_handle.fileno())
        end_offset = os.lseek(log_handle.fileno(), 0, os.SEEK_END)
        receipt = {
            "transaction": args.transaction,
            "record_count": len(records),
            "payload_sha256": payload_digest,
            "start_offset": start_offset,
            "end_offset": end_offset,
            "log_device": log_stat.st_dev,
            "log_inode": log_stat.st_ino,
            "commit_sequence": sequence - 1,
            "framing": "be32-json-v1",
            "durable": True,
        }
        atomic_json(args.commit_metadata, receipt, 0o644)
        publish_progress("committed")
        print(
            f"COMMIT_OK transaction={args.transaction} records={len(records)} digest={payload_digest} "
            f"ledger_inode={log_stat.st_ino} sequence={sequence - 1} end_offset={end_offset}"
        )
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    raise SystemExit(main())
