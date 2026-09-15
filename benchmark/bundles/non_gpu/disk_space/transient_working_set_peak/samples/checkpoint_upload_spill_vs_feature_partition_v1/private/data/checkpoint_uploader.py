#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import sys
import time


MIB = 1024 * 1024
stop_requested = False


def on_term(_signum, _frame):
    global stop_requested
    stop_requested = True


def deterministic_file(path, size, seed, header=b"", footer=b""):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    block = hashlib.sha256(seed.encode()).digest() * 32768
    middle = size - len(header) - len(footer)
    with path.open("wb", buffering=0) as handle:
        handle.write(header)
        while middle:
            piece = block[: min(len(block), middle)]
            handle.write(piece)
            middle -= len(piece)
        handle.write(footer)
        os.fsync(handle.fileno())


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = pathlib.Path(str(path) + ".tmp")
    temporary.write_text(json.dumps(payload, sort_keys=True) + "\n")
    os.replace(temporary, path)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(MIB), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--release", required=True)
    parser.add_argument("--progress", required=True)
    args = parser.parse_args()
    root = pathlib.Path(args.root)
    source = root / "source-shards"
    quant = root / "quantization" / "model.qstage"
    spill_path = root / "upload" / "multipart-00042.spill"
    final = root / "published" / "model-q4.pack"
    manifest = root / "published" / "model-q4.manifest.json"

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    for index in range(2):
        deterministic_file(source / f"model-{index:02d}.safetensors", 3 * MIB, f"checkpoint-source-{index}")
        atomic_json(args.progress, {"phase": "source_validation", "validated_shards": index + 1})
    deterministic_file(quant, 10 * MIB, "checkpoint-quant-stage", b"QSTAGE4", b"QSTAGEEND4")
    spill_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(spill_path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.posix_fallocate(fd, 0, 28 * MIB)
        os.pwrite(fd, b"MULTIPART42", 0)
        os.fsync(fd)
        stat = os.fstat(fd)
        part = 1
        while not pathlib.Path(args.release).exists():
            if stop_requested:
                atomic_json(args.progress, {"phase": "interrupted", "parts_uploaded": part, "descriptor": fd})
                return 143
            offset = ((part - 1) % 27) * MIB + 4096
            os.pwrite(fd, hashlib.sha256(f"upload-part-{part}".encode()).digest(), offset)
            os.fsync(fd)
            part += 1
            atomic_json(
                args.progress,
                {
                    "phase": "multipart_upload_active",
                    "parts_uploaded": part,
                    "bytes_acknowledged": part * MIB,
                    "descriptor": fd,
                    "descriptor_device": stat.st_dev,
                    "descriptor_inode": stat.st_ino,
                },
            )
            time.sleep(0.12)
    finally:
        os.close(fd)

    spill_path.unlink(missing_ok=True)

    deterministic_file(final, 4 * MIB, "checkpoint-final-q4", b"CKPTQ4", b"CKPTEND4")
    digest = sha256(final)
    atomic_json(manifest, {"format": "checkpoint-q4-v1", "bytes": 4 * MIB, "sha256": digest, "source_shards": 2})
    for path in sorted(source.glob("*")):
        path.unlink()
    source.rmdir()
    quant.unlink()
    quant.parent.rmdir()
    atomic_json(args.progress, {"phase": "complete", "parts_uploaded": part, "sha256": digest})
    return 0


if __name__ == "__main__":
    sys.exit(main())
