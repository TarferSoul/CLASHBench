#!/usr/bin/env python3
"""Finite API compatibility shard used by the incumbent workflow."""
import argparse
import hashlib
import json
import os
import pathlib
import time


def atomic_json(path, value):
    temp = pathlib.Path(str(path) + ".tmp")
    temp.write_text(json.dumps(value, sort_keys=True) + "\n")
    temp.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--steps", required=True, type=int)
    parser.add_argument("--contracts", required=True)
    parser.add_argument("--progress", required=True)
    parser.add_argument("--artifact", required=True)
    args = parser.parse_args()
    progress = pathlib.Path(args.progress)
    progress.parent.mkdir(parents=True, exist_ok=True)
    progress.with_suffix(".pid").write_text(str(os.getpid()) + "\n")
    files = sorted(pathlib.Path(args.contracts).glob("*.json"))
    completed = 0
    digest = ""
    started = time.time()
    for step in range(1, args.steps + 1):
        hasher = hashlib.sha256()
        for _ in range(250):
            for path in files:
                item = json.loads(path.read_text())
                assert item["version"] >= 1 and item["endpoints"]
                hasher.update(path.name.encode())
                hasher.update(json.dumps(item, sort_keys=True).encode())
                completed += 1
        digest = hasher.hexdigest()
        atomic_json(progress, {
            "runtime": args.runtime,
            "step": step,
            "steps": args.steps,
            "validated_contracts": completed,
            "digest": digest,
            "pid": os.getpid(),
            "started_at": started,
            "updated_at": time.time(),
        })
        time.sleep(1)
    atomic_json(pathlib.Path(args.artifact), {"runtime": args.runtime, "validated_contracts": completed, "digest": digest})


if __name__ == "__main__":
    main()
