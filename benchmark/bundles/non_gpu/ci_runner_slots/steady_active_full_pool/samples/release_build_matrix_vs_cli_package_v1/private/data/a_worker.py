#!/usr/bin/env python3
"""Finite Python release-build shard used by the incumbent workflow."""
import argparse
import hashlib
import json
import os
import pathlib
import py_compile
import tempfile
import time


def atomic_json(path, value):
    temp = pathlib.Path(str(path) + ".tmp")
    temp.write_text(json.dumps(value, sort_keys=True) + "\n")
    temp.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("debug", "optimized"), required=True)
    parser.add_argument("--steps", required=True, type=int)
    parser.add_argument("--source", required=True)
    parser.add_argument("--progress", required=True)
    parser.add_argument("--artifact", required=True)
    args = parser.parse_args()
    progress = pathlib.Path(args.progress)
    progress.parent.mkdir(parents=True, exist_ok=True)
    progress.with_suffix(".pid").write_text(str(os.getpid()) + "\n")
    files = sorted(pathlib.Path(args.source).rglob("*.py"))
    completed = 0
    digest = ""
    started = time.time()
    optimize = 0 if args.mode == "debug" else 2
    with tempfile.TemporaryDirectory(prefix=f"release-{args.mode}-") as tmp:
        tmp_root = pathlib.Path(tmp)
        for step in range(1, args.steps + 1):
            hasher = hashlib.sha256()
            for repeat in range(80):
                for index, path in enumerate(files):
                    target = tmp_root / f"{repeat}-{index}.pyc"
                    py_compile.compile(str(path), cfile=str(target), doraise=True, optimize=optimize)
                    payload = target.read_bytes()
                    if len(payload) < 16:
                        raise RuntimeError("invalid bytecode output")
                    hasher.update(payload)
                    completed += 1
            digest = hasher.hexdigest()
            atomic_json(progress, {
                "mode": args.mode,
                "step": step,
                "steps": args.steps,
                "verified_objects": completed,
                "digest": digest,
                "pid": os.getpid(),
                "started_at": started,
                "updated_at": time.time(),
            })
            time.sleep(1)
    atomic_json(pathlib.Path(args.artifact), {"mode": args.mode, "verified_objects": completed, "digest": digest})


if __name__ == "__main__":
    main()
