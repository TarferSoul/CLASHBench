#!/usr/bin/env python3
import argparse
import errno
import hashlib
import json
import os
import pathlib
import shutil
import sys


def request(path):
    value = json.loads(pathlib.Path(path).read_text())
    required = {"dataset_id", "seed", "output_dir", "shard_count", "shard_bytes", "total_bytes", "record_count", "format"}
    if not required.issubset(value):
        raise ValueError("request is missing required fields")
    if value["shard_count"] * value["shard_bytes"] != value["total_bytes"]:
        raise ValueError("request byte contract is inconsistent")
    return value


def shard_name(index, count):
    return f"tokens-{index:05d}-of-{count:05d}.bin"


def block_for(seed, name):
    digest = hashlib.sha256((seed + ":" + name).encode()).digest()
    return (digest * ((1024 * 1024 + len(digest) - 1) // len(digest)))[: 1024 * 1024]


def expected_sha(seed, name, size):
    block = block_for(seed, name)
    digest = hashlib.sha256()
    remaining = size
    while remaining:
        part = block[: min(len(block), remaining)]
        digest.update(part)
        remaining -= len(part)
    return digest.hexdigest()


def verify(req):
    output = pathlib.Path(req["output_dir"])
    manifest_path = output / "dataset_manifest.json"
    success_path = output / "_SUCCESS"
    if not manifest_path.is_file() or not success_path.is_file():
        raise ValueError("manifest or completion marker missing")
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("dataset_id") != req["dataset_id"] or manifest.get("format") != req["format"]:
        raise ValueError("manifest identity mismatch")
    if manifest.get("record_count") != req["record_count"] or manifest.get("total_bytes") != req["total_bytes"]:
        raise ValueError("manifest totals mismatch")
    files = manifest.get("files")
    if not isinstance(files, list) or len(files) != req["shard_count"]:
        raise ValueError("manifest shard count mismatch")
    actual_total = 0
    for index, entry in enumerate(files):
        name = shard_name(index, req["shard_count"])
        if entry.get("name") != name or entry.get("size") != req["shard_bytes"]:
            raise ValueError("manifest shard contract mismatch")
        path = output / name
        if not path.is_file() or path.stat().st_size != req["shard_bytes"]:
            raise ValueError("shard size mismatch")
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        expected = expected_sha(req["seed"], name, req["shard_bytes"])
        if actual != expected or entry.get("sha256") != expected:
            raise ValueError("shard checksum mismatch")
        actual_total += path.stat().st_size
    if actual_total != req["total_bytes"]:
        raise ValueError("payload byte total mismatch")
    manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    print(f"VERIFY_OK=1 files={len(files)} total_bytes={actual_total} manifest_sha256={manifest_sha}")


def build(req):
    output = pathlib.Path(req["output_dir"])
    staging = output.with_name("." + output.name + f".building-{os.getpid()}")
    if output.exists():
        shutil.rmtree(output)
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    entries = []
    stage = "initializing"
    try:
        for index in range(req["shard_count"]):
            name = shard_name(index, req["shard_count"])
            stage = name
            path = staging / name
            block = block_for(req["seed"], name)
            digest = hashlib.sha256()
            remaining = req["shard_bytes"]
            with path.open("wb", buffering=0) as handle:
                while remaining:
                    part = block[: min(len(block), remaining)]
                    handle.write(part)
                    digest.update(part)
                    remaining -= len(part)
                os.fsync(handle.fileno())
            entries.append({"name": name, "size": req["shard_bytes"], "sha256": digest.hexdigest()})
        manifest = {
            "dataset_id": req["dataset_id"],
            "format": req["format"],
            "record_count": req["record_count"],
            "total_bytes": req["total_bytes"],
            "files": entries,
        }
        stage = "dataset_manifest.json"
        (staging / "dataset_manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        (staging / "_SUCCESS").write_text("dataset_complete\n")
        os.rename(staging, output)
        verify(req)
    except OSError as exc:
        shutil.rmtree(staging, ignore_errors=True)
        if exc.errno == errno.ENOSPC:
            print(f"DATASET_BUILD_FAILED errno=28 stage={stage} reason=no_space_left", file=sys.stderr)
            return 28
        raise
    return 0


def main():
    ap = argparse.ArgumentParser(description="Build or verify deterministic tokenized dataset shards")
    sub = ap.add_subparsers(dest="mode", required=True)
    for name in ("build", "verify"):
        child = sub.add_parser(name)
        child.add_argument("--request", required=True)
    args = ap.parse_args()
    req = request(args.request)
    if args.mode == "verify":
        verify(req)
        return 0
    return build(req)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"VERIFY_OK=0 reason={exc}", file=sys.stderr)
        raise SystemExit(2)
