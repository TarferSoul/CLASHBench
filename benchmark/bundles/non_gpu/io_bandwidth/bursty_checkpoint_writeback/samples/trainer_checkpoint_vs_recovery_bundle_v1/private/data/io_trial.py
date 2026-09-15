#!/usr/bin/env python3
"""Run a command while sampling aggregate block I/O counters."""

import argparse
import json
import pathlib
import subprocess
import sys
import time


FIELDS = [
    "reads_completed",
    "reads_merged",
    "sectors_read",
    "read_ms",
    "writes_completed",
    "writes_merged",
    "sectors_written",
    "write_ms",
    "io_in_progress",
    "io_ms",
    "weighted_io_ms",
]


def read_diskstats():
    stats = {}
    for line in pathlib.Path("/proc/diskstats").read_text().splitlines():
        parts = line.split()
        if len(parts) < 14:
            continue
        name = parts[2]
        if name.startswith(("loop", "ram", "zram", "fd")):
            continue
        values = [int(value) for value in parts[3:14]]
        stats[name] = dict(zip(FIELDS, values))
    return stats


def aggregate_delta(before, after):
    delta = {field: 0 for field in FIELDS}
    devices = 0
    for name, end in after.items():
        start = before.get(name)
        if not start:
            continue
        local = {field: end[field] - start[field] for field in FIELDS}
        if local["sectors_written"] or local["sectors_read"] or local["writes_completed"] or local["reads_completed"]:
            devices += 1
            for field, value in local.items():
                delta[field] += value
    return delta, devices


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--result-dir", required=True)
    parser.add_argument("--interval", type=float, default=0.05)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        raise SystemExit("missing command")
    if args.command[0] == "--":
        args.command = args.command[1:]

    result_dir = pathlib.Path(args.result_dir)
    result_dir.mkdir(parents=True, exist_ok=True)
    stdout_path = result_dir / f"{args.label}.stdout"
    stderr_path = result_dir / f"{args.label}.stderr"
    rc_path = result_dir / f"{args.label}.rc"
    jsonl_path = result_dir / f"{args.label}_io.jsonl"
    summary_path = result_dir / f"{args.label}_io_summary.json"

    before = read_diskstats()
    started = time.time()
    max_in_progress = 0
    samples = 0
    with stdout_path.open("w") as stdout, stderr_path.open("w") as stderr:
        proc = subprocess.Popen(args.command, stdout=stdout, stderr=stderr, text=True)
        with jsonl_path.open("w") as jsonl:
            while proc.poll() is None:
                now = time.time()
                current = read_diskstats()
                in_progress = sum(item.get("io_in_progress", 0) for item in current.values())
                max_in_progress = max(max_in_progress, in_progress)
                jsonl.write(json.dumps({"t": now, "io_in_progress": in_progress, "stats": current}) + "\n")
                jsonl.flush()
                samples += 1
                time.sleep(args.interval)
        rc = proc.returncode
    finished = time.time()
    after = read_diskstats()
    delta, device_count = aggregate_delta(before, after)
    rc_path.write_text(str(rc) + "\n")
    summary = {
        "label": args.label,
        "rc": rc,
        "elapsed_seconds": finished - started,
        "samples": samples,
        "device_count": device_count,
        "delta": delta,
        "max_io_in_progress": max_in_progress,
    }
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps(summary, sort_keys=True))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
