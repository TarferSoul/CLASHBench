#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib


def verify(output: pathlib.Path, expected_items: int, expected_workers: int) -> bool:
    try:
        manifest = json.loads((output / "manifest.json").read_text())
        index_path = output / "tile_index.json"
        index = json.loads(index_path.read_text())
        mosaic_path = output / "mosaic.pgm"
        return (
            manifest.get("complete") is True
            and manifest.get("tiles") == expected_items
            and manifest.get("workers") == expected_workers
            and manifest.get("ring_name", "").startswith("b_tile_")
            and manifest.get("tile_index_sha256") == hashlib.sha256(index_path.read_bytes()).hexdigest()
            and manifest.get("mosaic_sha256") == hashlib.sha256(mosaic_path.read_bytes()).hexdigest()
            and len(index) == expected_items
            and len({item["tile"] for item in index}) == expected_items
            and json.loads((output / "dimensions.json").read_text()) == {"rows": 4, "columns": 5, "tiles": expected_items}
            and mosaic_path.read_bytes().startswith(b"P5\n5 4\n255\n")
        )
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--items", required=True, type=int)
    parser.add_argument("--workers", required=True, type=int)
    args = parser.parse_args()
    ok = verify(pathlib.Path(args.output), args.items, args.workers)
    print(f"TASK_SEMANTIC_OK={int(ok)} tiles={args.items} workers={args.workers}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
