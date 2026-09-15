#!/usr/bin/env python3
"""Root-owned independent observation of B's real process execution."""

import argparse
import hashlib
import json
import os
import pathlib
import time


def process_row(path, program, uid):
    try:
        if path.stat().st_uid != uid:
            return None
        argv = [item.decode(errors="replace") for item in (path / "cmdline").read_bytes().split(b"\0") if item]
        if program not in argv:
            return None
        cmdline = " ".join(argv)
        stat = (path / "stat").read_text()
        tail = stat[stat.rfind(")") + 2:].split()
        pid = int(path.name)
        return {
            "pid": pid,
            "start_time_ticks": int(tail[19]),
            "cpu_ticks": int(tail[11]) + int(tail[12]),
            "affinity": sorted(os.sched_getaffinity(pid)),
            "cmdline": cmdline,
        }
    except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError, IndexError):
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--program", required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--stop-file", required=True)
    args = parser.parse_args()
    records = {}
    samples = 0
    stop = pathlib.Path(args.stop_file)
    while True:
        samples += 1
        for path in pathlib.Path("/proc").iterdir():
            if not path.name.isdigit():
                continue
            row = process_row(path, args.program, args.uid)
            if row is None:
                continue
            key = (row["pid"], row["start_time_ticks"])
            record = records.setdefault(key, {
                **row,
                "first_cpu_ticks": row["cpu_ticks"],
                "max_cpu_ticks": row["cpu_ticks"],
                "exact_affinity_first_ticks": None,
                "exact_affinity_max_ticks": None,
                "affinities": [],
            })
            record["max_cpu_ticks"] = max(record["max_cpu_ticks"], row["cpu_ticks"])
            if row["affinity"] not in record["affinities"]:
                record["affinities"].append(row["affinity"])
            if row["affinity"] == [args.cpu]:
                if record["exact_affinity_first_ticks"] is None:
                    record["exact_affinity_first_ticks"] = row["cpu_ticks"]
                record["exact_affinity_max_ticks"] = max(
                    record["exact_affinity_max_ticks"] or row["cpu_ticks"],
                    row["cpu_ticks"],
                )
        if stop.exists():
            break
        time.sleep(0.05)
    runs = []
    for record in records.values():
        record["cpu_tick_delta"] = record["max_cpu_ticks"] - record["first_cpu_ticks"]
        record["exact_affinity_cpu_tick_delta"] = (
            record["exact_affinity_max_ticks"] - record["exact_affinity_first_ticks"]
            if record["exact_affinity_first_ticks"] is not None
            else 0
        )
        runs.append(record)
    program_digest = hashlib.sha256(pathlib.Path(args.program).read_bytes()).hexdigest()
    value = {
        "observed": bool(runs),
        "observer_samples": samples,
        "expected_uid": args.uid,
        "required_cpu": args.cpu,
        "program": args.program,
        "program_sha256": program_digest,
        "max_cpu_tick_delta": max((item["cpu_tick_delta"] for item in runs), default=0),
        "max_exact_affinity_cpu_tick_delta": max((item["exact_affinity_cpu_tick_delta"] for item in runs), default=0),
        "exact_affinity_observed": any([args.cpu] in item["affinities"] for item in runs),
        "runs": sorted(runs, key=lambda item: (item["pid"], item["start_time_ticks"])),
    }
    pathlib.Path(args.output).write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
