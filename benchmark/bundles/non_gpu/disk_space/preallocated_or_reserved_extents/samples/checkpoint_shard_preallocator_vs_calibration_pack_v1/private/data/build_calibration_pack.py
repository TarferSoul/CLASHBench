#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import sys


parser = argparse.ArgumentParser(description="Build a fully allocated quantization calibration pack")
parser.add_argument("--spec", required=True)
args = parser.parse_args()
spec = json.load(open(args.spec, encoding="utf-8"))
artifact = spec["artifact"]
manifest = spec["manifest"]
size = int(spec["allocated_bytes"])
stripe_bytes = int(spec["stripe_bytes"])
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
    offset = 0
    stripe_number = 0
    seed = f"{spec['model']}:{spec['calibration_examples']}:{spec['format_version']}".encode()
    while offset < size:
        digest = hashlib.blake2b(seed + stripe_number.to_bytes(8, "big"), digest_size=64).digest()
        length = min(stripe_bytes, size - offset)
        stripe = (digest * (length // len(digest) + 1))[:length]
        os.pwrite(fd, stripe, offset)
        offset += length
        stripe_number += 1
    os.pwrite(fd, header, 0)
    os.pwrite(fd, trailer, size - len(trailer))
    os.fsync(fd)
finally:
    os.close(fd)

stripe_digests = []
full = hashlib.sha256()
with open(artifact, "rb") as handle:
    while True:
        stripe = handle.read(stripe_bytes)
        if not stripe:
            break
        full.update(stripe)
        stripe_digests.append(hashlib.sha256(stripe).hexdigest())
stat = os.stat(artifact)
payload = {
    "artifact": artifact,
    "size_bytes": stat.st_size,
    "allocated_bytes": stat.st_blocks * 512,
    "sha256": full.hexdigest(),
    "stripe_bytes": stripe_bytes,
    "stripe_sha256": stripe_digests,
    "model": spec["model"],
    "calibration_examples": spec["calibration_examples"],
    "format_version": spec["format_version"],
}
with open(manifest + ".next", "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.replace(manifest + ".next", manifest)
print(f"CALIBRATION_PACK_OK path={artifact} size={stat.st_size} allocated={stat.st_blocks * 512} stripes={len(stripe_digests)} sha256={full.hexdigest()}")
