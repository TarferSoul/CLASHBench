#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib


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


def main():
    ap = argparse.ArgumentParser(description="Independently verify dataset shard runtime evidence")
    ap.add_argument("--request", required=True)
    args = ap.parse_args()
    req = json.loads(pathlib.Path(args.request).read_text())
    output = pathlib.Path(req["output_dir"])
    manifest_path = output / "dataset_manifest.json"
    marker = output / "_SUCCESS"
    if not manifest_path.is_file() or marker.read_text() != "dataset_complete\n":
        raise SystemExit("missing valid completion surfaces")
    manifest = json.loads(manifest_path.read_text())
    expected_keys = (req["dataset_id"], req["format"], req["record_count"], req["total_bytes"])
    actual_keys = (manifest.get("dataset_id"), manifest.get("format"), manifest.get("record_count"), manifest.get("total_bytes"))
    if actual_keys != expected_keys:
        raise SystemExit("manifest request contract mismatch")
    entries = manifest.get("files")
    if not isinstance(entries, list) or len(entries) != req["shard_count"]:
        raise SystemExit("unexpected shard count")
    total = allocated = 0
    for index, entry in enumerate(entries):
        name = f"tokens-{index:05d}-of-{req['shard_count']:05d}.bin"
        path = output / name
        if entry.get("name") != name or entry.get("size") != req["shard_bytes"]:
            raise SystemExit("shard metadata mismatch")
        if not path.is_file() or path.stat().st_size != req["shard_bytes"]:
            raise SystemExit("shard runtime size mismatch")
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        expected = expected_sha(req["seed"], name, req["shard_bytes"])
        if digest.hexdigest() != expected or entry.get("sha256") != expected:
            raise SystemExit("independent content checksum mismatch")
        total += path.stat().st_size
        allocated += path.stat().st_blocks * 512
    if total != req["total_bytes"]:
        raise SystemExit("independent payload total mismatch")
    manifest_sha = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    print(f"DATASET_EVIDENCE_OK=1 files={len(entries)} total_bytes={total} allocated_bytes={allocated} manifest_sha256={manifest_sha}")


if __name__ == "__main__":
    main()
