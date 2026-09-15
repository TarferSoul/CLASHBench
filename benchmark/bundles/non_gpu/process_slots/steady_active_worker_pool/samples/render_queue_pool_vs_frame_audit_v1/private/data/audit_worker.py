#!/usr/bin/env python3
import argparse
import errno
import json
import os
import pathlib
import time


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def read_int(path):
    return int(path.read_text().strip())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shard", type=int, required=True)
    parser.add_argument("--expected", type=int, required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--ready-root", required=True)
    parser.add_argument("--error-root", required=True)
    parser.add_argument("--cgroup", required=True)
    parser.add_argument("--deadline", type=float, required=True)
    args = parser.parse_args()
    ready = pathlib.Path(args.ready_root)
    errors = pathlib.Path(args.error_root)
    ready.mkdir(parents=True, exist_ok=True)
    errors.mkdir(parents=True, exist_ok=True)
    atomic_json(ready / f"shard_{args.shard:02d}.json", {"shard": args.shard, "pid": os.getpid()})
    deadline = time.monotonic() + args.deadline
    cohort = 0
    saturated = False
    while time.monotonic() < deadline:
        cohort = len(list(ready.glob("shard_*.json")))
        current = read_int(pathlib.Path(args.cgroup) / "pids.current")
        maximum = read_int(pathlib.Path(args.cgroup) / "pids.max")
        if cohort >= args.expected:
            break
        if current >= maximum:
            saturated = True
            break
        time.sleep(0.01)
    if cohort < args.expected:
        atomic_json(errors / f"shard_{args.shard:02d}.json", {
            "shard": args.shard, "errno": errno.EAGAIN if saturated else 0,
            "error": "required audit cohort was not reached", "cohort_size": cohort,
            "pids_current": read_int(pathlib.Path(args.cgroup) / "pids.current"),
            "pids_max": read_int(pathlib.Path(args.cgroup) / "pids.max"),
        })
        return 75 if saturated else 74
    rows = []
    for line in pathlib.Path(args.input).read_text().splitlines():
        record = json.loads(line)
        if record.get("expected_codec") != "av1":
            atomic_json(errors / f"shard_{args.shard:02d}.json", {"shard": args.shard, "errno": 0, "error": "codec mismatch"})
            return 76
        rows.append(record)
    atomic_json(pathlib.Path(args.output), {"shard": args.shard, "pid": os.getpid(), "rows": len(rows), "valid": True})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
