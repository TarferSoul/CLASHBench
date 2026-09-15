#!/usr/bin/env python3
import argparse
import errno
import hashlib
import json
import os
import pathlib
import shutil
import sys

CHUNK = 1024 * 1024


def source_digest(path: pathlib.Path) -> str:
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    canonical = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canonical).hexdigest()


def shard_block(source_sha: str, release: str, shard: int) -> bytes:
    seed = hashlib.sha256(f"{source_sha}:{release}:shard-{shard:02d}".encode()).digest()
    return (seed * (CHUNK // len(seed) + 1))[:CHUNK]


def expected_shard_digest(source_sha: str, release: str, shard: int, size: int) -> str:
    digest = hashlib.sha256()
    block = shard_block(source_sha, release, shard)
    remaining = size
    while remaining:
        chunk = block[: min(len(block), remaining)]
        digest.update(chunk)
        remaining -= len(chunk)
    return digest.hexdigest()


def write_shard(path: pathlib.Path, source_sha: str, release: str, shard: int, size: int) -> str:
    digest = hashlib.sha256()
    block = shard_block(source_sha, release, shard)
    remaining = size
    with path.open("xb", buffering=0) as handle:
        while remaining:
            chunk = block[: min(len(block), remaining)]
            handle.write(chunk)
            digest.update(chunk)
            remaining -= len(chunk)
        os.fsync(handle.fileno())
    return digest.hexdigest()


def fsync_directory(path: pathlib.Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the incident-response vector index")
    parser.add_argument("--source", required=True)
    parser.add_argument("--data-root", required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--shards", type=int, default=6)
    parser.add_argument("--shard-bytes", type=int, default=4 * 1024 * 1024)
    args = parser.parse_args()
    source = pathlib.Path(args.source)
    data_root = pathlib.Path(args.data_root)
    receipt = pathlib.Path(args.receipt)
    source_sha = source_digest(source)
    staging = data_root / "staging" / f"{args.release}.{os.getpid()}"
    release_root = data_root / "releases" / args.release
    try:
        staging.mkdir(parents=True, exist_ok=False)
        shards = []
        for shard in range(args.shards):
            path = staging / f"vectors-{shard:02d}.hnsw"
            digest = write_shard(path, source_sha, args.release, shard, args.shard_bytes)
            shards.append({"name": path.name, "sha256": digest, "bytes": args.shard_bytes, "ordinal": shard})
        manifest = {
            "format": "incident-vector-index-v1",
            "release": args.release,
            "source_sha256": source_sha,
            "shard_count": args.shards,
            "shard_bytes": args.shard_bytes,
            "total_bytes": args.shards * args.shard_bytes,
            "shards": shards,
        }
        manifest_path = staging / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        with manifest_path.open("rb") as handle:
            os.fsync(handle.fileno())
        releases = release_root.parent
        releases.mkdir(parents=True, exist_ok=True)
        if release_root.exists():
            raise FileExistsError(f"release already exists: {release_root}")
        os.replace(staging, release_root)
        fsync_directory(releases)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt_tmp = receipt.with_name(receipt.name + ".tmp")
        receipt_tmp.write_text(json.dumps({"release": args.release, "source_sha256": source_sha, "shard_count": args.shards, "total_bytes": args.shards * args.shard_bytes, "data_root": str(data_root)}, sort_keys=True, indent=2) + "\n")
        os.replace(receipt_tmp, receipt)
        print(f"VECTOR_INDEX_OK=1 release={args.release} shards={args.shards} bytes={args.shards * args.shard_bytes} source_sha256={source_sha} data_root={data_root}")
        return 0
    except OSError as exc:
        if exc.errno == errno.ENOSPC:
            print(f"TARGET_INDEX_ENOSPC path={data_root} errno=28 release={args.release}", file=sys.stderr)
            return 28
        raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())

