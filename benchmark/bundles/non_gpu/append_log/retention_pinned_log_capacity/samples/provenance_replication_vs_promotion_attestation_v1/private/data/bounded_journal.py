#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import sys
import time


class JournalError(Exception):
    pass


class CapacityError(JournalError):
    def __init__(self, required, active_remaining, allocated, capacity, pinned):
        super().__init__("configured journal capacity exhausted")
        self.required = required
        self.active_remaining = active_remaining
        self.allocated = allocated
        self.capacity = capacity
        self.pinned = pinned


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def digest_bytes(value):
    return hashlib.sha256(value).hexdigest()


def load_records(path):
    rows = []
    seen = set()
    for number, line in enumerate(pathlib.Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict) or not isinstance(value.get("event_id"), str):
            raise JournalError(f"line {number}: object with string event_id required")
        if value["event_id"] in seen:
            raise JournalError(f"line {number}: duplicate event_id")
        seen.add(value["event_id"])
        rows.append(value)
    if not rows:
        raise JournalError("input contains no events")
    return rows


def atomic_json(path, value, mode=0o660):
    path = pathlib.Path(path)
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    payload = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        os.write(fd, payload)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(temporary, mode)
    os.replace(temporary, path)
    directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


class Journal:
    def __init__(self, root):
        self.root = pathlib.Path(root)
        self.config_path = self.root / "config.json"
        self.manifest_path = self.root / "manifest.json"
        self.lock_path = self.root / ".append.lock"
        self.segments_root = self.root / "segments"

    def initialize(self, capacity, segment_size):
        if capacity <= 0 or segment_size <= 0 or capacity % segment_size:
            raise JournalError("capacity must be a positive multiple of segment size")
        self.segments_root.mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, 0o2770)
        os.chmod(self.segments_root, 0o2770)
        self.lock_path.touch(mode=0o660, exist_ok=True)
        os.chmod(self.lock_path, 0o660)
        atomic_json(
            self.config_path,
            {"format": "bounded-segment-journal-v1", "capacity_bytes": capacity, "segment_bytes": segment_size},
        )
        atomic_json(
            self.manifest_path,
            {
                "format": "bounded-segment-journal-v1",
                "generation": 0,
                "ack_generation": 0,
                "next_sequence": 1,
                "next_segment": 1,
                "segments": [],
            },
        )

    def config(self):
        return json.loads(self.config_path.read_text(encoding="utf-8"))

    def manifest(self):
        return json.loads(self.manifest_path.read_text(encoding="utf-8"))

    def lock(self):
        handle = self.lock_path.open("a+")
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        return handle

    def segment_path(self, entry):
        return self.segments_root / entry["file"]

    def logical_bytes(self, entry):
        with self.segment_path(entry).open("rb") as handle:
            return handle.read(int(entry["used_bytes"]))

    def frames(self, manifest=None):
        manifest = manifest or self.manifest()
        values = []
        for entry in sorted(manifest["segments"], key=lambda item: item["generation"]):
            payload = self.logical_bytes(entry)
            for line in payload.splitlines():
                if line:
                    values.append(json.loads(line))
        return values

    def transaction_blob(self, records, transaction, actor, first_sequence):
        payload_text = "\n".join(canonical(row) for row in records) + "\n"
        payload_digest = digest_bytes(payload_text.encode())
        frames = [
            {
                "seq": first_sequence,
                "frame": "BEGIN",
                "transaction": transaction,
                "actor": actor,
                "record_count": len(records),
                "payload_sha256": payload_digest,
            }
        ]
        for record in records:
            frames.append(
                {
                    "seq": first_sequence + len(frames),
                    "frame": "ENTRY",
                    "transaction": transaction,
                    "payload": record,
                }
            )
        frames.append(
            {
                "seq": first_sequence + len(frames),
                "frame": "COMMIT",
                "transaction": transaction,
                "record_count": len(records),
                "payload_sha256": payload_digest,
            }
        )
        blob = ("\n".join(canonical(frame) for frame in frames) + "\n").encode()
        return blob, payload_digest, frames

    def measure(self, records, transaction, actor="model-registry-promotion-client"):
        manifest = self.manifest()
        blob, _, _ = self.transaction_blob(records, transaction, actor, manifest["next_sequence"])
        return len(blob)

    def _allocate_segment(self, manifest, segment_size):
        generation = int(manifest["next_segment"])
        segment_id = f"segment-{generation:06d}"
        path = self.segments_root / f"{segment_id}.seg"
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o660)
        try:
            try:
                os.posix_fallocate(fd, 0, segment_size)
            except (AttributeError, OSError):
                os.ftruncate(fd, segment_size)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.chmod(path, 0o660)
        stat = path.stat()
        entry = {
            "segment_id": segment_id,
            "generation": generation,
            "file": path.name,
            "device": stat.st_dev,
            "inode": stat.st_ino,
            "used_bytes": 0,
            "sealed": False,
            "retention_pinned": False,
            "sha256": None,
        }
        manifest["segments"].append(entry)
        manifest["next_segment"] = generation + 1
        return entry

    def _seal(self, entry):
        path = self.segment_path(entry)
        fd = os.open(path, os.O_RDWR)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        entry["sealed"] = True
        entry["retention_pinned"] = True
        entry["sha256"] = digest_bytes(self.logical_bytes(entry))
        entry["sealed_unix_ns"] = time.time_ns()

    def append(self, records, transaction, actor, commit_path):
        with self.lock():
            config = self.config()
            manifest = self.manifest()
            if any(frame.get("transaction") == transaction for frame in self.frames(manifest)):
                raise JournalError(f"transaction already exists: {transaction}")
            blob, payload_digest, frames = self.transaction_blob(
                records, transaction, actor, manifest["next_sequence"]
            )
            segment_size = int(config["segment_bytes"])
            capacity = int(config["capacity_bytes"])
            if len(blob) > segment_size:
                raise JournalError(f"transaction requires {len(blob)} bytes, larger than one segment")
            active = next((item for item in manifest["segments"] if not item["sealed"]), None)
            active_remaining = segment_size - int(active["used_bytes"]) if active else 0
            allocated = len(manifest["segments"]) * segment_size
            pinned = sum(segment_size for item in manifest["segments"] if item["retention_pinned"])
            if active is None or active_remaining < len(blob):
                if allocated + segment_size > capacity:
                    raise CapacityError(len(blob), active_remaining, allocated, capacity, pinned)
                if active is not None:
                    self._seal(active)
                active = self._allocate_segment(manifest, segment_size)
                active_remaining = segment_size
            path = self.segment_path(active)
            start_offset = int(active["used_bytes"])
            fd = os.open(path, os.O_RDWR)
            try:
                written = os.pwrite(fd, blob, start_offset)
                if written != len(blob):
                    raise JournalError(f"short segment write: {written} of {len(blob)}")
                os.fsync(fd)
                stat = os.fstat(fd)
            finally:
                os.close(fd)
            end_offset = start_offset + len(blob)
            active["used_bytes"] = end_offset
            manifest["next_sequence"] = frames[-1]["seq"] + 1
            manifest["generation"] = int(manifest["generation"]) + 1
            atomic_json(self.manifest_path, manifest)
            commit = {
                "transaction": transaction,
                "record_count": len(records),
                "payload_sha256": payload_digest,
                "first_sequence": frames[0]["seq"],
                "commit_sequence": frames[-1]["seq"],
                "segment_id": active["segment_id"],
                "segment_device": stat.st_dev,
                "segment_inode": stat.st_ino,
                "start_offset": start_offset,
                "end_offset": end_offset,
                "durable": True,
                "manifest_generation": manifest["generation"],
            }
            atomic_json(commit_path, commit, 0o660)
            return commit

    def inventory(self):
        config = self.config()
        manifest = self.manifest()
        segment_size = int(config["segment_bytes"])
        capacity = int(config["capacity_bytes"])
        segments = []
        for entry in sorted(manifest["segments"], key=lambda item: item["generation"]):
            path = self.segment_path(entry)
            stat = path.stat()
            logical_digest = digest_bytes(self.logical_bytes(entry))
            segments.append(
                {
                    **entry,
                    "path": str(path),
                    "current_device": stat.st_dev,
                    "current_inode": stat.st_ino,
                    "size_bytes": stat.st_size,
                    "allocated_blocks_bytes": stat.st_blocks * 512,
                    "logical_sha256": logical_digest,
                }
            )
        active = next((item for item in segments if not item["sealed"]), None)
        allocated = len(segments) * segment_size
        return {
            "format": manifest["format"],
            "capacity_bytes": capacity,
            "segment_bytes": segment_size,
            "allocated_bytes": allocated,
            "unallocated_bytes": capacity - allocated,
            "active_remaining_bytes": segment_size - int(active["used_bytes"]) if active else 0,
            "pinned_bytes": sum(segment_size for item in segments if item["retention_pinned"]),
            "pinned_segment_count": sum(1 for item in segments if item["retention_pinned"]),
            "manifest_generation": manifest["generation"],
            "ack_generation": manifest["ack_generation"],
            "next_sequence": manifest["next_sequence"],
            "segments": segments,
        }

    def health(self):
        config = self.config()
        manifest = self.manifest()
        segment_size = int(config["segment_bytes"])
        capacity = int(config["capacity_bytes"])
        if len(manifest["segments"]) * segment_size > capacity:
            raise JournalError("allocated segments exceed configured capacity")
        active = [entry for entry in manifest["segments"] if not entry["sealed"]]
        if len(active) > 1:
            raise JournalError("more than one active segment")
        sequences = []
        for entry in manifest["segments"]:
            path = self.segment_path(entry)
            stat = path.stat()
            if stat.st_size != segment_size:
                raise JournalError(f"wrong fixed size for {entry['segment_id']}")
            if (stat.st_dev, stat.st_ino) != (entry["device"], entry["inode"]):
                raise JournalError(f"identity changed for {entry['segment_id']}")
            logical = self.logical_bytes(entry)
            if entry["sealed"] and digest_bytes(logical) != entry["sha256"]:
                raise JournalError(f"sealed digest changed for {entry['segment_id']}")
            for line in logical.splitlines():
                sequences.append(int(json.loads(line)["seq"]))
        if sequences and sequences != list(range(sequences[0], sequences[-1] + 1)):
            raise JournalError("journal sequence is not contiguous")
        return self.inventory()

    def acknowledge(self, segment_id, expected_digest, archive_copy):
        archive_copy = pathlib.Path(archive_copy)
        with self.lock():
            config = self.config()
            manifest = self.manifest()
            matches = [item for item in manifest["segments"] if item["segment_id"] == segment_id]
            if len(matches) != 1:
                raise JournalError(f"unknown segment: {segment_id}")
            entry = matches[0]
            if not entry["sealed"] or not entry["retention_pinned"]:
                raise JournalError("segment is not retention-pinned")
            if entry["sha256"] != expected_digest:
                raise JournalError("acknowledgement digest does not match manifest")
            archive_digest = digest_bytes(archive_copy.read_bytes())
            if archive_digest != expected_digest:
                raise JournalError("staged archive copy digest does not match")
            path = self.segment_path(entry)
            stat = path.stat()
            if (stat.st_dev, stat.st_ino) != (entry["device"], entry["inode"]):
                raise JournalError("segment identity changed before acknowledgement")
            if digest_bytes(self.logical_bytes(entry)) != expected_digest:
                raise JournalError("segment content changed before acknowledgement")
            reclaiming = path.with_name(path.name + f".acknowledged.{os.getpid()}")
            os.replace(path, reclaiming)
            manifest["segments"] = [item for item in manifest["segments"] if item["segment_id"] != segment_id]
            manifest["ack_generation"] = int(manifest["ack_generation"]) + 1
            manifest["generation"] = int(manifest["generation"]) + 1
            atomic_json(self.manifest_path, manifest)
            reclaiming.unlink()
            directory_fd = os.open(self.segments_root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            return {
                "segment_id": segment_id,
                "sha256": expected_digest,
                "freed_bytes": int(config["segment_bytes"]),
                "ack_generation": manifest["ack_generation"],
                "archive_copy": str(archive_copy),
            }


def command_init(args):
    Journal(args.store).initialize(args.capacity, args.segment_size)
    print(f"INIT_OK store={args.store} capacity_bytes={args.capacity} segment_bytes={args.segment_size}")


def command_append(args):
    journal = Journal(args.store)
    records = load_records(args.input)
    try:
        commit = journal.append(records, args.transaction, args.actor, args.commit)
    except CapacityError as error:
        print(
            "CAPACITY_EXCEEDED "
            f"required_bytes={error.required} active_remaining_bytes={error.active_remaining} "
            f"allocated_bytes={error.allocated} capacity_bytes={error.capacity} "
            f"pinned_bytes={error.pinned}",
            file=sys.stderr,
        )
        return 75
    print(
        f"COMMIT_OK transaction={commit['transaction']} records={commit['record_count']} "
        f"segment={commit['segment_id']} start_offset={commit['start_offset']} "
        f"end_offset={commit['end_offset']} durable=1"
    )
    return 0


def command_inventory(args):
    print(json.dumps(Journal(args.store).inventory(), sort_keys=True, indent=2))


def command_health(args):
    inventory = Journal(args.store).health()
    print(
        f"JOURNAL_HEALTHY=1 allocated_bytes={inventory['allocated_bytes']} "
        f"pinned_segments={inventory['pinned_segment_count']} next_sequence={inventory['next_sequence']}"
    )


def command_measure(args):
    journal = Journal(args.store)
    records = load_records(args.input)
    print(journal.measure(records, args.transaction, args.actor))


def command_contains(args):
    present = any(frame.get("transaction") == args.transaction for frame in Journal(args.store).frames())
    print(f"TRANSACTION_PRESENT={1 if present else 0} transaction={args.transaction}")
    return 0 if present else 1


def command_ack(args):
    result = Journal(args.store).acknowledge(args.segment, args.digest, args.archive_copy)
    print(
        f"ACK_OK segment={result['segment_id']} digest={result['sha256']} "
        f"freed_bytes={result['freed_bytes']} ack_generation={result['ack_generation']}"
    )


def main():
    parser = argparse.ArgumentParser(description="Fixed-capacity segmented model-provenance spool")
    subparsers = parser.add_subparsers(dest="command", required=True)
    init_parser = subparsers.add_parser("init")
    init_parser.add_argument("--store", required=True)
    init_parser.add_argument("--capacity", required=True, type=int)
    init_parser.add_argument("--segment-size", required=True, type=int)
    init_parser.set_defaults(func=command_init)
    append_parser = subparsers.add_parser("append")
    append_parser.add_argument("--store", required=True)
    append_parser.add_argument("--input", required=True)
    append_parser.add_argument("--transaction", required=True)
    append_parser.add_argument("--commit", required=True)
    append_parser.add_argument("--actor", default="model-registry-promotion-client")
    append_parser.set_defaults(func=command_append)
    for name, func in (("inventory", command_inventory), ("health", command_health)):
        child = subparsers.add_parser(name)
        child.add_argument("--store", required=True)
        child.set_defaults(func=func)
    measure_parser = subparsers.add_parser("measure")
    measure_parser.add_argument("--store", required=True)
    measure_parser.add_argument("--input", required=True)
    measure_parser.add_argument("--transaction", required=True)
    measure_parser.add_argument("--actor", default="model-registry-promotion-client")
    measure_parser.set_defaults(func=command_measure)
    contains_parser = subparsers.add_parser("contains")
    contains_parser.add_argument("--store", required=True)
    contains_parser.add_argument("--transaction", required=True)
    contains_parser.set_defaults(func=command_contains)
    ack_parser = subparsers.add_parser("ack")
    ack_parser.add_argument("--store", required=True)
    ack_parser.add_argument("--segment", required=True)
    ack_parser.add_argument("--digest", required=True)
    ack_parser.add_argument("--archive-copy", required=True)
    ack_parser.set_defaults(func=command_ack)
    args = parser.parse_args()
    try:
        return args.func(args) or 0
    except (JournalError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"JOURNAL_ERROR {error}", file=sys.stderr)
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
