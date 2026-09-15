#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import struct
import sys


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(reason: str) -> int:
    print(f"INDEX_OK=0 reason={reason}")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    parser.add_argument("--manifest", required=True)
    args = parser.parse_args()

    try:
        job = json.loads(pathlib.Path(args.job).read_text())
        manifest_path = pathlib.Path(args.manifest)
        manifest = json.loads(manifest_path.read_text())
    except Exception as exc:
        return fail(f"json_load_failed:{type(exc).__name__}")

    output = manifest_path.parent
    embeddings = output / "embeddings.npy"
    index = output / "ticket_index.faiss"
    checks = {
        "schema": manifest.get("schema") == "support-ticket-index-manifest-v1",
        "status": manifest.get("status") == "complete",
        "workers": manifest.get("worker_count") == job.get("required_worker_count"),
        "rows": manifest.get("total_rows") == job.get("expected_total_rows"),
        "shards": manifest.get("shard_row_counts") == job.get("expected_shard_row_counts"),
        "checksum": manifest.get("semantic_checksum") == job.get("expected_semantic_checksum"),
        "embeddings_exists": embeddings.is_file(),
        "index_exists": index.is_file(),
    }
    if embeddings.is_file():
        checks["embeddings_sha"] = manifest.get("embeddings_sha256") == file_sha256(embeddings)
        with embeddings.open("rb") as handle:
            checks["npy_magic"] = handle.read(6) == b"\x93NUMPY"
    if index.is_file():
        checks["index_sha"] = manifest.get("index_sha256") == file_sha256(index)
        with index.open("rb") as handle:
            checks["index_magic"] = handle.read(16) == b"CBFAISS-FLAT-IP\x00"
            if checks["index_magic"]:
                rows, dims = struct.unpack("<II", handle.read(8))
                checks["index_shape"] = rows == job.get("expected_total_rows") and dims == job.get("embedding_dimensions")

    failed = sorted(name for name, ok in checks.items() if not ok)
    if failed:
        return fail("checks_failed:" + ",".join(failed))
    print(
        "INDEX_OK=1 rows={} workers={} checksum={}".format(
            manifest["total_rows"],
            manifest["worker_count"],
            manifest["semantic_checksum"],
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

