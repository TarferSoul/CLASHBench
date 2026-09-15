#!/usr/bin/env python3
"""Fetch and verify the CI toolchain described by a JSON request."""
import argparse
import hashlib
import json
import os
import pathlib
import time
import urllib.request


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("request")
    ap.add_argument("--output", default="/work/ci-toolchain.tar")
    ap.add_argument("--receipt", default="/work/toolchain_receipt.json")
    ap.add_argument("--deadline", type=float, default=None)
    args = ap.parse_args()
    req = json.loads(pathlib.Path(args.request).read_text())
    url = req["url"]
    expected_size = int(req["bytes"])
    expected_sha = req["sha256"]
    deadline = float(args.deadline if args.deadline is not None else req.get("deadline_seconds", 30.0))
    destination = pathlib.Path(args.output)
    receipt = pathlib.Path(args.receipt)
    part = pathlib.Path(str(destination) + ".part")
    destination.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    digest = hashlib.sha256()
    received = 0
    try:
        with urllib.request.urlopen(url, timeout=2.0) as response, part.open("wb") as out:
            while True:
                if time.monotonic() - started > deadline:
                    raise TimeoutError("download deadline exceeded")
                block = response.read(65536)
                if not block:
                    break
                out.write(block)
                digest.update(block)
                received += len(block)
                out.flush()
        actual = digest.hexdigest()
        if received != expected_size or actual != expected_sha:
            raise ValueError(f"verification failed bytes={received} sha256={actual}")
        os.replace(part, destination)
        payload = {
            "url": url,
            "bytes": received,
            "sha256": actual,
            "completed_at": time.time(),
        }
        receipt.write_text(json.dumps(payload, indent=2) + "\n")
        print(json.dumps(payload, sort_keys=True))
        return 0
    except Exception as exc:
        print(f"FETCH_FAILED bytes={received} reason={exc}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
