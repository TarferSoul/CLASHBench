#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import re
import time


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--project", type=int, required=True)
    parser.add_argument("--slot", type=int, required=True)
    parser.add_argument("--generation", type=int, required=True)
    args = parser.parse_args()

    source = Path(args.source)
    payload = source.read_bytes()
    symbols = sorted(set(re.findall(rb"dependency_[A-Za-z0-9_]+", payload)))
    imports = sorted(set(re.findall(rb"(?m)^(?:from|import)\s+([A-Za-z0-9_.]+)", payload)))
    deadline = time.monotonic() + args.seconds
    digest = hashlib.sha256(payload).digest()
    passes = 0
    while time.monotonic() < deadline:
        digest = hashlib.sha256(digest + payload).digest()
        passes += 1
    result = {
        "project": args.project,
        "slot": args.slot,
        "generation": args.generation,
        "source": source.name,
        "source_bytes": len(payload),
        "symbols": len(symbols),
        "imports": [item.decode("ascii") for item in imports],
        "analysis_passes": passes,
        "dependency_fingerprint": digest.hex(),
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    tmp = output.with_suffix(".tmp")
    tmp.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    tmp.replace(output)


if __name__ == "__main__":
    main()
