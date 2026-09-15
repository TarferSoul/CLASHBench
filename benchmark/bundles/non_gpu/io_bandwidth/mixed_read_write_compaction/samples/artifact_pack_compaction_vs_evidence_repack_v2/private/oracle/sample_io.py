#!/usr/bin/env python3
"""Collect high-resolution device, pressure, capacity, and phase evidence."""

import argparse
import json
import os
from pathlib import Path
import time


def pressure(path):
    result = {}
    try:
        for line in Path(path).read_text().splitlines():
            fields = line.split()
            result[fields[0]] = {
                key: float(value) if key != "total" else int(value)
                for key, value in (field.split("=", 1) for field in fields[1:])
            }
    except (FileNotFoundError, PermissionError, ValueError):
        pass
    return result


def diskstats():
    result = {}
    for line in Path("/proc/diskstats").read_text().splitlines():
        fields = line.split()
        if len(fields) < 14:
            continue
        name = fields[2]
        if name.startswith(("loop", "ram", "fd", "sr")):
            continue
        values = list(map(int, fields[3:14]))
        result[name] = {
            "major": int(fields[0]),
            "minor": int(fields[1]),
            "reads_completed": values[0],
            "reads_merged": values[1],
            "read_sectors": values[2],
            "read_ms": values[3],
            "writes_completed": values[4],
            "writes_merged": values[5],
            "write_sectors": values[6],
            "write_ms": values[7],
            "in_flight": values[8],
            "io_ms": values[9],
            "weighted_io_ms": values[10],
        }
    return result


def key_values(path):
    result = {}
    try:
        for line in Path(path).read_text().splitlines():
            fields = line.split()
            if len(fields) == 2 and fields[1].lstrip("-").isdigit():
                result[fields[0]] = int(fields[1])
    except (FileNotFoundError, PermissionError):
        pass
    return result


def cpu_capacity(path):
    try:
        quota, period = Path(path).read_text().split()
        if quota == "max":
            return {"quota": "max", "period": int(period), "quota_cores": os.cpu_count() or 1}
        return {
            "quota": int(quota),
            "period": int(period),
            "quota_cores": int(quota) / int(period),
        }
    except (FileNotFoundError, PermissionError, ValueError):
        return {"quota": "unknown", "period": 0, "quota_cores": 0}


def cgroup_dir():
    for line in Path("/proc/self/cgroup").read_text().splitlines():
        fields = line.split(":", 2)
        if fields[0] == "0":
            return Path("/sys/fs/cgroup") / fields[2].lstrip("/")
    return Path("/sys/fs/cgroup")


def cpu_total():
    fields = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
    values = list(map(int, fields))
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return {"total": sum(values), "idle": idle}


def memory():
    wanted = {"MemAvailable", "MemTotal", "SwapFree", "SwapTotal"}
    result = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value, *_ = line.replace(":", "").split()
        if key in wanted:
            result[key] = int(value)
    return result


def filesystem(path):
    stats = os.statvfs(path)
    item = os.stat(path)
    return {
        "path": str(Path(path).resolve()),
        "st_dev": item.st_dev,
        "major": os.major(item.st_dev),
        "minor": os.minor(item.st_dev),
        "free_bytes": stats.f_bavail * stats.f_frsize,
        "free_inodes": stats.f_favail,
    }


def a_progress(runtime):
    root = Path(runtime)
    result = {"sequence": 0, "completed_cycles": 0, "workers": 0, "phases": {}}
    for state_file in sorted(root.glob("worker_*.json")):
        try:
            state = json.loads(state_file.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            continue
        result["workers"] += 1
        result["sequence"] += int(state.get("sequence", 0))
        result["completed_cycles"] += int(state.get("completed_cycles", 0))
        phase = state.get("phase", "unknown")
        result["phases"][phase] = result["phases"].get(phase, 0) + 1
    return result


def b_progress(output_root):
    path = Path(output_root) / "repack_progress.json"
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--stop-file", required=True)
    parser.add_argument("--a-runtime", required=True)
    parser.add_argument("--a-root", required=True)
    parser.add_argument("--b-input", required=True)
    parser.add_argument("--b-output", required=True)
    parser.add_argument("--interval", type=float, default=0.1)
    args = parser.parse_args()
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    cg = cgroup_dir()
    with output.open("w", encoding="utf-8") as handle:
        while True:
            try:
                locks = sum(1 for _ in Path("/proc/locks").open())
            except (FileNotFoundError, PermissionError):
                locks = -1
            sample = {
                "wall_time": time.time(),
                "monotonic": time.monotonic(),
                "diskstats": diskstats(),
                "host_io_pressure": pressure("/proc/pressure/io"),
                "host_cpu_pressure": pressure("/proc/pressure/cpu"),
                "cgroup_io_pressure": pressure(cg / "io.pressure"),
                "cgroup_cpu_pressure": pressure(cg / "cpu.pressure"),
                "cgroup_cpu_stat": key_values(cg / "cpu.stat"),
                "cgroup_cpu_capacity": cpu_capacity(cg / "cpu.max"),
                "cgroup_memory_events": key_values(cg / "memory.events"),
                "cpu": cpu_total(),
                "memory_kib": memory(),
                "a_filesystem": filesystem(args.a_root),
                "b_input_filesystem": filesystem(args.b_input),
                "b_output_filesystem": filesystem(args.b_output),
                "a_progress": a_progress(args.a_runtime),
                "b_progress": b_progress(args.b_output),
                "locks_total": locks,
            }
            handle.write(json.dumps(sample, sort_keys=True) + "\n")
            handle.flush()
            if Path(args.stop_file).exists():
                break
            time.sleep(args.interval)


if __name__ == "__main__":
    main()
