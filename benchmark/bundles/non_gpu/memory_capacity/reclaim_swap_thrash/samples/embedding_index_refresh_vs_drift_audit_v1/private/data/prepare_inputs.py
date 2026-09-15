#!/usr/bin/env python3
"""Create deterministic packed-vector fixtures for the two ML workflows."""

import argparse
import hashlib
import json
import os
from pathlib import Path

MIB = 1024 * 1024
CHUNK = 8 * MIB


def create_fixture(path, metadata_path, size_mib, seed):
    path = Path(path)
    metadata_path = Path(metadata_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    remaining = size_mib * MIB
    with path.open("wb") as handle:
        block_index = 0
        while remaining:
            length = min(CHUNK, remaining)
            token = hashlib.sha256(f"packed-embedding:{seed}:{block_index}".encode()).digest()
            repeats, extra = divmod(length, len(token))
            payload = token * repeats + token[:extra]
            handle.write(payload)
            digest.update(payload)
            remaining -= length
            block_index += 1
        handle.flush()
        os.fsync(handle.fileno())
    fd = os.open(path, os.O_RDONLY)
    try:
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
    except (AttributeError, OSError):
        pass
    finally:
        os.close(fd)
    metadata_path.write_text(json.dumps({"size_bytes": size_mib * MIB, "seed": seed, "sha256": digest.hexdigest(), "device": path.stat().st_dev, "inode": path.stat().st_ino}, sort_keys=True, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--a-path", required=True)
    parser.add_argument("--a-meta", required=True)
    parser.add_argument("--b-path", required=True)
    parser.add_argument("--b-meta", required=True)
    parser.add_argument("--size-mib", type=int, default=896)
    args = parser.parse_args()
    create_fixture(args.a_path, args.a_meta, args.size_mib, 61)
    create_fixture(args.b_path, args.b_meta, args.size_mib, 97)


if __name__ == "__main__":
    main()
