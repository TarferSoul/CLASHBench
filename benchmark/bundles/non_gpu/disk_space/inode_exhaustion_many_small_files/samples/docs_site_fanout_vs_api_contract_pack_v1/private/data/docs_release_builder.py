#!/usr/bin/env python3
"""Build and continuously validate an operations documentation release."""
import argparse
import hashlib
import json
import os
import signal
import time
from pathlib import Path

stopping = False


def stop(_signum, _frame):
    global stopping
    stopping = True


def create_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")


def replace_existing_json(path, value):
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    with path.open("r+", encoding="utf-8") as stream:
        stream.seek(0)
        stream.write(encoded)
        stream.truncate()
        stream.flush()
        os.fsync(stream.fileno())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--pages", type=int, required=True)
    parser.add_argument("--search", type=int, required=True)
    parser.add_argument("--assets", type=int, required=True)
    args = parser.parse_args()
    root = Path(args.root)
    pages = root / "pages"
    search = root / "search-index"
    assets = root / "compiled-assets"
    pages.mkdir(parents=True)
    search.mkdir()
    assets.mkdir()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    for index in range(args.pages):
        (pages / f"operation-{index:03d}.html").write_text(
            f"<html><body><h1>Operation {index:03d}</h1><p>Validated runbook release.</p></body></html>\n",
            encoding="utf-8",
        )
    for index in range(args.search):
        create_json(search / f"fragment-{index:03d}.json", {
            "fragment": index,
            "pages": [f"operation-{(index * 3 + offset) % args.pages:03d}" for offset in range(3)],
        })
    for index in range(args.assets):
        (assets / f"theme-{index:03d}.css").write_text(
            f".operation-{index:03d}{{display:block;color:#202428}}\n", encoding="utf-8"
        )

    anchor = pages / "operation-000.html"
    anchor_hash = hashlib.sha256(anchor.read_bytes()).hexdigest()
    progress = root / "validation-progress.json"
    create_json(progress, {"release": "operations-docs-2026.08", "validation_passes": 0})
    create_json(root / "site-manifest.json", {
        "release": "operations-docs-2026.08",
        "published": True,
        "pages": args.pages,
        "search_fragments": args.search,
        "assets": args.assets,
        "anchor_sha256": anchor_hash,
    })
    passes = 0
    while not stopping:
        passes += 1
        replace_existing_json(progress, {
            "release": "operations-docs-2026.08",
            "validation_passes": passes,
            "anchor_sha256": anchor_hash,
            "updated_at_ns": time.time_ns(),
        })
        time.sleep(0.12)


if __name__ == "__main__":
    main()
