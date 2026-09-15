#!/usr/bin/env python3
import errno
import hashlib
import json
import os
import pathlib
import shutil
import sys
import time


MIB = 1024 * 1024


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
    temporary = pathlib.Path(str(path) + ".tmp")
    temporary.parent.mkdir(parents=True, exist_ok=True)
    temporary.write_text(json.dumps(payload, sort_keys=True) + "\n")
    os.replace(temporary, path)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(MIB), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    if len(sys.argv) != 2:
        print("usage: publish-feature-partition SPEC", file=sys.stderr)
        return 2
    spec = json.loads(pathlib.Path(sys.argv[1]).read_text())
    output = pathlib.Path(spec["output"])
    manifest = pathlib.Path(spec["manifest"])
    staging = output.parent / ".staging"
    progress = output.parent / "publish-progress.json"
    shutil.rmtree(staging, ignore_errors=True)
    output.unlink(missing_ok=True)
    manifest.unlink(missing_ok=True)
    progress.unlink(missing_ok=True)
    staging.mkdir(parents=True, exist_ok=True)
    try:
        deterministic_file(staging / "columns.arrow", spec["column_bytes"], "feature-columns-20260804")
        atomic_json(progress, {"phase": "columns_encoded"})
        deterministic_file(staging / "dictionary.bin", spec["dictionary_bytes"], "feature-dictionary-20260804")
        atomic_json(progress, {"phase": "dictionary_ready"})
        pending = output.with_suffix(".fsp.pending")
        deterministic_file(pending, spec["final_bytes"], "feature-final-20260804", b"FSPART3", b"ROWGROUP3")
        atomic_json(progress, {"phase": "atomic_publish_peak"})
        time.sleep(0.4)
        os.replace(pending, output)
        digest = sha256(output)
        atomic_json(
            manifest,
            {"format": "feature-partition-v3", "bytes": spec["final_bytes"], "rows": spec["rows"], "sha256": digest},
        )
        shutil.rmtree(staging)
        atomic_json(progress, {"phase": "complete", "sha256": digest})
        print(f"FEATURE_PUBLISH_OK=1 path={output} bytes={output.stat().st_size} sha256={digest}")
        return 0
    except OSError as exc:
        shutil.rmtree(staging, ignore_errors=True)
        output.with_suffix(".fsp.pending").unlink(missing_ok=True)
        output.unlink(missing_ok=True)
        manifest.unlink(missing_ok=True)
        if exc.errno == errno.ENOSPC:
            print(f"FEATURE_PUBLISH_FAIL=ENOSPC errno={exc.errno} path={exc.filename}", file=sys.stderr)
            return 28
        raise


if __name__ == "__main__":
    sys.exit(main())
