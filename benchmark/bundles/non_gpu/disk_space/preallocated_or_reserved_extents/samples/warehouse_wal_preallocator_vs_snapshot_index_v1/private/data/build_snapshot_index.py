#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import sys


parser = argparse.ArgumentParser(description="Build a fully allocated warehouse snapshot index")
parser.add_argument("--spec", required=True)
args = parser.parse_args()
spec = json.load(open(args.spec, encoding="utf-8"))
artifact = spec["artifact"]
manifest = spec["manifest"]
size = int(spec["allocated_bytes"])
header = spec["header"].encode()
trailer = spec["trailer"].encode()
os.makedirs(os.path.dirname(artifact), exist_ok=True)
for path in (artifact, manifest, manifest + ".next"):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

fd = os.open(artifact, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o640)
try:
    try:
        os.posix_fallocate(fd, 0, size)
    except OSError as exc:
        print(f"ALLOCATION_FAILED errno={exc.errno} path={artifact} bytes={size}", file=sys.stderr)
        raise
    chunk_bytes = 1024 * 1024
    written = 0
    index = 0
    seed = f"{spec['snapshot']}:{spec['partition_count']}:{spec['format_version']}".encode()
    while written < size:
        digest = hashlib.sha256(seed + index.to_bytes(8, "big")).digest()
        chunk = (digest * (chunk_bytes // len(digest) + 1))[: min(chunk_bytes, size - written)]
        os.pwrite(fd, chunk, written)
        written += len(chunk)
        index += 1
    os.pwrite(fd, header, 0)
    os.pwrite(fd, trailer, size - len(trailer))
    os.fsync(fd)
finally:
    os.close(fd)

with open(artifact, "rb") as handle:
    sha256 = hashlib.file_digest(handle, "sha256").hexdigest()
stat = os.stat(artifact)
payload = {
    "artifact": artifact,
    "size_bytes": stat.st_size,
    "allocated_bytes": stat.st_blocks * 512,
    "sha256": sha256,
    "snapshot": spec["snapshot"],
    "partition_count": spec["partition_count"],
    "format_version": spec["format_version"],
}
with open(manifest + ".next", "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(manifest + ".next", manifest)
print(f"SNAPSHOT_INDEX_OK path={artifact} size={stat.st_size} allocated={stat.st_blocks * 512} sha256={sha256}")

