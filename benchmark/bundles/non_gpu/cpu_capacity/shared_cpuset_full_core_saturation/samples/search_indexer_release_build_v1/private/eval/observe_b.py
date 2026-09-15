#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import time


stopping = False


def stop(_signum, _frame):
    global stopping
    stopping = True


def identity(pid):
    proc = pathlib.Path(f"/proc/{pid}")
    fields = (proc / "stat").read_text().split()
    return {
        "pid": pid,
        "ppid": int(fields[3]),
        "start_ticks": int(fields[21]),
        "cpu_ticks": int(fields[13]) + int(fields[14]),
        "uid": proc.stat().st_uid,
        "affinity": sorted(os.sched_getaffinity(pid)),
        "cmdline": (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace"),
    }


def digest(path):
    try:
        return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    except OSError:
        return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--program", required=True)
    parser.add_argument("--cpus", required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--watch-files", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    selected = [int(value) for value in args.cpus.split(",")]
    watched = [value for value in args.watch_files.split(",") if value]
    records = {}
    hashes = {path: [] for path in watched}
    max_concurrent = 0
    max_concurrent_busy = 0
    previous_ticks = {}
    last_seen = 0.0
    samples = 0
    while not stopping:
        now = time.time()
        current = []
        for entry in pathlib.Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                item = identity(int(entry.name))
            except (OSError, ValueError, ProcessLookupError):
                continue
            if item["uid"] != args.uid or args.program not in item["cmdline"]:
                continue
            key = f"{item['pid']}:{item['start_ticks']}"
            current.append((key, item))
            record = records.setdefault(
                key,
                {
                    "pid": item["pid"],
                    "ppid": item["ppid"],
                    "start_ticks": item["start_ticks"],
                    "uid": item["uid"],
                    "first_seen": now,
                    "last_seen": now,
                    "min_cpu_ticks": item["cpu_ticks"],
                    "max_cpu_ticks": item["cpu_ticks"],
                    "affinities": [],
                },
            )
            record["last_seen"] = now
            record["min_cpu_ticks"] = min(record["min_cpu_ticks"], item["cpu_ticks"])
            record["max_cpu_ticks"] = max(record["max_cpu_ticks"], item["cpu_ticks"])
            if item["affinity"] not in record["affinities"]:
                record["affinities"].append(item["affinity"])
        if current:
            last_seen = now
        max_concurrent = max(max_concurrent, len(current))
        busy = sum(item["cpu_ticks"] > previous_ticks.get(key, item["cpu_ticks"]) for key, item in current)
        max_concurrent_busy = max(max_concurrent_busy, busy)
        previous_ticks = {key: item["cpu_ticks"] for key, item in current}
        if current or (last_seen and now - last_seen < 0.6):
            for path in watched:
                value = digest(path)
                if value and value not in hashes[path]:
                    hashes[path].append(value)
        samples += 1
        time.sleep(0.05)
    total_ticks = sum(record["max_cpu_ticks"] - record["min_cpu_ticks"] for record in records.values())
    payload = {
        "schema": "root-b-process-observation-v1",
        "program": args.program,
        "selected_cpus": selected,
        "expected_uid": args.uid,
        "sample_count": samples,
        "max_concurrent_processes": max_concurrent,
        "max_concurrent_busy_processes": max_concurrent_busy,
        "total_cpu_ticks_delta": total_ticks,
        "processes": sorted(records.values(), key=lambda item: (item["pid"], item["start_ticks"])),
        "artifact_hashes_seen_during_process": hashes,
    }
    path = pathlib.Path(args.output)
    path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.chmod(path, 0o600)


if __name__ == "__main__":
    main()
