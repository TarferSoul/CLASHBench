#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import sys


def fail(reason: str) -> None:
    print(f"ABI_MATRIX_VERIFY_OK=0 reason={reason}")
    raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--compilers-per-worker", type=int, required=True)
    args = parser.parse_args()
    input_root = Path(args.input)
    output_root = Path(args.output)
    manifest_path = output_root / "abi-manifest.json"
    stage_path = output_root / "descendant-stage.json"
    if not manifest_path.is_file() or not stage_path.is_file():
        fail("missing_manifest_or_stage")
    manifest = json.loads(manifest_path.read_text())
    stage = json.loads(stage_path.read_text())
    expected = args.workers * args.compilers_per_worker
    if manifest.get("schema") != "abi-matrix-v1":
        fail("schema")
    if manifest.get("workers") != args.workers or manifest.get("compilers_per_worker") != args.compilers_per_worker:
        fail("recipe")
    if stage != {
        "compiler_descendants": expected,
        "compilers_per_worker": args.compilers_per_worker,
        "packages_reaching_descendants": args.workers,
        "workers": args.workers,
    }:
        fail("descendant_stage")
    records = manifest.get("records", [])
    if len(records) != expected or manifest.get("object_count") != expected:
        fail("record_count")
    seen = set()
    for record in records:
        key = (record.get("package"), record.get("unit"))
        if key in seen:
            fail("duplicate_record")
        seen.add(key)
        obj = output_root / record.get("object", "")
        source = input_root / record.get("source", "")
        if not obj.is_file() or not source.is_file():
            fail("missing_object_or_source")
        if hashlib.sha256(obj.read_bytes()).hexdigest() != record.get("object_sha256"):
            fail("object_digest")
        if int(record.get("defined_symbols", 0)) < 1801:
            fail("symbol_count")
    if len(seen) != expected:
        fail("coverage")
    print(
        f"ABI_MATRIX_VERIFY_OK=1 objects={expected} workers={args.workers} "
        f"compilers_per_worker={args.compilers_per_worker}"
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ABI_MATRIX_VERIFY_OK=0 reason={type(exc).__name__}")
        sys.exit(1)
