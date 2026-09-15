#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import time


stop_requested = False


def stop_handler(_signum, _frame):
    global stop_requested
    stop_requested = True


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def content_block(name):
    digest = hashlib.sha256(("mobile-symbol-archive-v1:" + name).encode()).digest()
    return (digest * ((512 * 1024 + len(digest) - 1) // len(digest)))[: 512 * 1024]


def write_bundle(path, size):
    block = content_block(path.name)
    digest = hashlib.sha256()
    remaining = size
    with path.open("wb", buffering=0) as handle:
        while remaining:
            part = block[: min(len(block), remaining)]
            handle.write(part)
            digest.update(part)
            remaining -= len(part)
        os.fsync(handle.fileno())
    return digest.hexdigest()


def main():
    ap = argparse.ArgumentParser(description="Package and verify mobile debug-symbol uploads")
    ap.add_argument("--output", required=True)
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--total-bytes", required=True, type=int)
    ap.add_argument("--files", required=True, type=int)
    args = ap.parse_args()
    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)

    output = pathlib.Path(args.output)
    runtime = pathlib.Path(args.runtime)
    output.mkdir(parents=True, exist_ok=False)
    runtime.mkdir(parents=True, exist_ok=True)
    base, extra = divmod(args.total_bytes, args.files)
    architectures = ("arm64-v8a", "armeabi-v7a", "x86_64", "x86")
    entries = []
    for index in range(args.files):
        kind = "native-symbols" if index % 2 == 0 else "source-maps"
        arch = architectures[index % len(architectures)]
        name = f"app-9.4.0-{arch}-{kind}-{index:02d}.bundle"
        size = base + (1 if index < extra else 0)
        path = output / name
        checksum = write_bundle(path, size)
        stat = path.stat()
        entries.append(
            {
                "name": name,
                "arch": arch,
                "kind": kind,
                "size": size,
                "sha256": checksum,
                "allocated_bytes": stat.st_blocks * 512,
            }
        )

    index = {
        "release": "android-app-9.4.0+94017",
        "mapping_id": "a44d29e7-ef6c-4f73-a82b-c00c28e5f820",
        "files": entries,
        "total_bytes": sum(item["size"] for item in entries),
    }
    atomic_json(output / "archive_index.json", index)
    index_sha = hashlib.sha256((output / "archive_index.json").read_bytes()).hexdigest()
    atomic_json(
        runtime / "ready.json",
        {"state": "ready", "index_sha256": index_sha, "files": len(entries), "total_bytes": index["total_bytes"]},
    )

    verified_bytes = 0
    passes = 0
    upload_offset = 0
    while not stop_requested:
        for entry in entries:
            path = output / entry["name"]
            digest = hashlib.sha256()
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(512 * 1024), b""):
                    digest.update(chunk)
                    verified_bytes += len(chunk)
                    upload_offset += len(chunk)
            if digest.hexdigest() != entry["sha256"]:
                atomic_json(runtime / "progress.json", {"state": "corrupt", "file": entry["name"]})
                return 3
            if stop_requested:
                break
        passes += 1
        atomic_json(
            runtime / "progress.json",
            {
                "state": "uploading_verified_symbols",
                "passes": passes,
                "verified_bytes": verified_bytes,
                "upload_offset": upload_offset,
                "index_sha256": index_sha,
            },
        )
        time.sleep(0.1)

    atomic_json(
        runtime / "progress.json",
        {
            "state": "gracefully_stopped",
            "passes": passes,
            "verified_bytes": verified_bytes,
            "upload_offset": upload_offset,
            "index_sha256": index_sha,
        },
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
