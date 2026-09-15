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


def payload_block(spec: dict) -> bytes:
    seed = hashlib.sha256(
        f"{spec['release']}:{spec['module']}:{spec['source_revision']}".encode()
    ).digest()
    return (seed * (CHUNK // len(seed) + 1))[:CHUNK]


def expected_digest(spec: dict) -> str:
    digest = hashlib.sha256()
    block = payload_block(spec)
    remaining = int(spec["layer_bytes"])
    while remaining:
        part = block[: min(len(block), remaining)]
        digest.update(part)
        remaining -= len(part)
    return digest.hexdigest()


def write_layer(path: pathlib.Path, spec: dict) -> str:
    digest = hashlib.sha256()
    block = payload_block(spec)
    remaining = int(spec["layer_bytes"])
    with path.open("xb", buffering=0) as handle:
        while remaining:
            part = block[: min(len(block), remaining)]
            handle.write(part)
            digest.update(part)
            remaining -= len(part)
        os.fsync(handle.fileno())
    return digest.hexdigest()


def fsync_directory(path: pathlib.Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build and load the edge-gateway OCI release")
    parser.add_argument("--spec", required=True)
    parser.add_argument("--store", required=True)
    parser.add_argument("--receipt", required=True)
    args = parser.parse_args()
    spec_path = pathlib.Path(args.spec)
    store = pathlib.Path(args.store)
    receipt = pathlib.Path(args.receipt)
    spec = json.loads(spec_path.read_text())
    release = str(spec["release"])
    staging = store / "tmp" / f"{release}.{os.getpid()}"
    release_root = store / "releases" / release
    try:
        staging.mkdir(parents=True, exist_ok=False)
        layer_tmp = staging / "layer.blob"
        digest = write_layer(layer_tmp, spec)
        if digest != expected_digest(spec):
            raise RuntimeError("deterministic layer digest mismatch")
        blob_root = store / "content/blobs/sha256"
        blob_root.mkdir(parents=True, exist_ok=True)
        blob = blob_root / digest
        os.replace(layer_tmp, blob)
        fsync_directory(blob_root)
        release_root.mkdir(parents=True, exist_ok=True)
        index = {
            "schemaVersion": 2,
            "release": release,
            "platform": spec["platform"],
            "layer": {"digest": f"sha256:{digest}", "size": int(spec["layer_bytes"]), "mediaType": spec["media_type"]},
            "module": spec["module"],
            "source_revision": spec["source_revision"],
        }
        index_tmp = release_root / "index.json.tmp"
        index_tmp.write_text(json.dumps(index, sort_keys=True, indent=2) + "\n")
        with index_tmp.open("rb") as handle:
            os.fsync(handle.fileno())
        os.replace(index_tmp, release_root / "index.json")
        fsync_directory(release_root)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt_tmp = receipt.with_name(receipt.name + ".tmp")
        receipt_tmp.write_text(json.dumps({"release": release, "digest": digest, "bytes": int(spec["layer_bytes"]), "store": str(store)}, sort_keys=True, indent=2) + "\n")
        os.replace(receipt_tmp, receipt)
        print(f"OCI_LOAD_OK=1 release={release} digest={digest} bytes={spec['layer_bytes']} store={store}")
        return 0
    except OSError as exc:
        if exc.errno == errno.ENOSPC:
            print(f"TARGET_STORE_ENOSPC path={store} errno=28 release={release}", file=sys.stderr)
            return 28
        raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())

