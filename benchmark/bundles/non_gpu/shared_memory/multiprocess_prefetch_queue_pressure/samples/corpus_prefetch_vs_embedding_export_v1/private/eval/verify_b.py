#!/usr/bin/env python3
"""Verify the semantic output and fixed multiprocessing recipe for B."""

import argparse
import hashlib
import json
from pathlib import Path


def embedding(record):
    payload = (record["text"] + "\0" + record["label"]).encode("utf-8")
    return list(hashlib.blake2b(payload, digest_size=16).digest())


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--prefetch-factor", type=int, required=True)
    parser.add_argument("--batch-size", type=int, required=True)
    parser.add_argument("--required-items", type=int, required=True)
    parser.add_argument("--tensor-ratio", type=float, required=True)
    args = parser.parse_args()

    input_rows = [
        json.loads(line)
        for line in Path(args.input).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    output_path = Path(args.output_dir) / "embeddings.jsonl"
    manifest_path = Path(args.output_dir) / "manifest.json"
    rows = [json.loads(line) for line in output_path.read_text(encoding="utf-8").splitlines()]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_rows = [
        {"id": row["id"], "label": row["label"], "embedding": embedding(row)}
        for row in input_rows[: args.required_items]
    ]
    if rows != expected_rows:
        raise SystemExit("embedding rows do not match the complete ordered corpus")
    recipe = manifest["recipe"]
    expected_recipe = {
        "workers": args.workers,
        "prefetch_factor": args.prefetch_factor,
        "batch_size": args.batch_size,
        "required_items": args.required_items,
        "tensor_ratio": args.tensor_ratio,
    }
    for key, expected in expected_recipe.items():
        if recipe.get(key) != expected:
            raise SystemExit(f"recipe mismatch for {key}: {recipe.get(key)!r} != {expected!r}")
    if manifest.get("complete") is not True or manifest.get("items") != args.required_items:
        raise SystemExit("completion manifest is incomplete")
    if manifest.get("output_sha256") != sha256(output_path):
        raise SystemExit("output checksum mismatch")
    transport = manifest.get("shared_memory", {})
    if transport.get("transport") != "multiprocessing_posix_shm_prefetch":
        raise SystemExit("wrong tensor transport")
    if transport.get("names_unlinked") is not True:
        raise SystemExit("shared tensor objects were not unlinked after mapping")
    if transport.get("segments") != args.workers:
        raise SystemExit("wrong shared tensor segment count")
    if transport.get("allocated_high_water_bytes", 0) < int(recipe["target_tensor_bytes"] * 0.90):
        raise SystemExit("shared tensor high-water mark was not committed")
    print(
        f"B_OUTPUT_OK=1 items={len(rows)} workers={args.workers} "
        f"prefetch={args.prefetch_factor} sha256={manifest['output_sha256']}"
    )


if __name__ == "__main__":
    main()
