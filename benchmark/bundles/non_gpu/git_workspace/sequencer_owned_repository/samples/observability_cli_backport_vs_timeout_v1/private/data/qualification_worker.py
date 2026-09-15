#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import time


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic_write(path, value):
    path = pathlib.Path(path)
    tmp = pathlib.Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n")
    tmp.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--interval", type=float, default=0.25)
    args = parser.parse_args()
    repo = pathlib.Path(args.repo)
    log = pathlib.Path(args.log)
    log.parent.mkdir(parents=True, exist_ok=True)
    generation = 0
    while True:
        generation += 1
        started = time.time()
        proc = subprocess.run(
            [
                "python3",
                "-m",
                "unittest",
                "-q",
                "tests.test_parser",
                "tests.test_query_plan",
                "tests.test_flag_validation",
            ],
            cwd=repo,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        state = {
            "generation": generation,
            "pid": os.getpid(),
            "test_rc": proc.returncode,
            "duration_ms": int((time.time() - started) * 1000),
            "parser_sha256": sha256(repo / "edgecli/parser.py"),
            "finished_at": time.time(),
        }
        atomic_write(args.status, state)
        with log.open("a") as stream:
            stream.write(json.dumps(state, sort_keys=True) + "\n")
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
