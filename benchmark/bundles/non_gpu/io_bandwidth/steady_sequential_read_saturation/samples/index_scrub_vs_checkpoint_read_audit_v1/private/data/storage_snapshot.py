#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import time


def diskstats():
    values = {}
    for line in pathlib.Path("/proc/diskstats").read_text().splitlines():
        fields = line.split()
        if len(fields) < 14:
            continue
        major, minor, name = fields[:3]
        if name.startswith(("loop", "ram", "zram", "fd", "sr")):
            continue
        values[f"{major}:{minor}:{name}"] = {
            "read_ios": int(fields[3]),
            "read_sectors": int(fields[5]),
            "read_ms": int(fields[6]),
            "io_ms": int(fields[12]),
            "weighted_io_ms": int(fields[13]),
        }
    return values


def cpu_stat():
    parts = pathlib.Path("/proc/stat").read_text().splitlines()[0].split()[1:]
    nums = [int(value) for value in parts]
    idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
    return {"total": sum(nums), "idle": idle}


def cgroup_cpu():
    affinity = len(os.sched_getaffinity(0))
    stat_path = pathlib.Path("/sys/fs/cgroup/cpu.stat")
    max_path = pathlib.Path("/sys/fs/cgroup/cpu.max")
    usage = 0
    capacity = float(affinity)
    if stat_path.exists():
        for line in stat_path.read_text().splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] == "usage_usec":
                usage = int(parts[1])
        if max_path.exists():
            quota, period = max_path.read_text().split()[:2]
            if quota != "max":
                capacity = min(capacity, int(quota) / int(period))
    return {"usage_usec": usage, "capacity_cores": capacity, "affinity_cores": affinity}


def meminfo():
    out = {}
    for line in pathlib.Path("/proc/meminfo").read_text().splitlines():
        key, rest = line.split(":", 1)
        if key in {"MemTotal", "MemAvailable"}:
            out[key] = int(rest.split()[0]) * 1024
    return out


def path_info(path):
    st = os.stat(path)
    fs = os.statvfs(path)
    return {
        "path": path,
        "st_dev": st.st_dev,
        "major": os.major(st.st_dev),
        "minor": os.minor(st.st_dev),
        "free_bytes": fs.f_bavail * fs.f_frsize,
    }


def snapshot(args):
    payload = {
        "wall_ns": time.time_ns(),
        "monotonic_ns": time.monotonic_ns(),
        "diskstats": diskstats(),
        "cpu": cpu_stat(),
        "cgroup_cpu": cgroup_cpu(),
        "memory": meminfo(),
        "a_path": path_info(args.a_path),
        "b_path": path_info(args.b_path),
    }
    pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def summarize(args):
    before = json.loads(pathlib.Path(args.before).read_text())
    after = json.loads(pathlib.Path(args.after).read_text())
    deltas = {}
    for key in sorted(set(before["diskstats"]) | set(after["diskstats"])):
        old = before["diskstats"].get(key, {})
        new = after["diskstats"].get(key, {})
        deltas[key] = {
            field: max(0, int(new.get(field, 0)) - int(old.get(field, 0)))
            for field in ("read_ios", "read_sectors", "read_ms", "io_ms", "weighted_io_ms")
        }
    device = args.device or max(deltas, key=lambda k: (deltas[k]["read_sectors"], deltas[k]["read_ios"]), default="")
    device_delta = deltas.get(device, {field: 0 for field in ("read_ios", "read_sectors", "read_ms", "io_ms", "weighted_io_ms")})
    elapsed_ns = int(args.elapsed_ns)
    cpu_total = after["cpu"]["total"] - before["cpu"]["total"]
    cpu_idle = after["cpu"]["idle"] - before["cpu"]["idle"]
    cpu_busy = (cpu_total - cpu_idle) / cpu_total if cpu_total > 0 else 1.0
    cgroup_usage = after["cgroup_cpu"]["usage_usec"] - before["cgroup_cpu"]["usage_usec"]
    cgroup_capacity = min(before["cgroup_cpu"]["capacity_cores"], after["cgroup_cpu"]["capacity_cores"])
    cgroup_busy = cgroup_usage / (elapsed_ns / 1000) / cgroup_capacity if elapsed_ns > 0 and cgroup_capacity > 0 else 1.0
    payload = {
        "elapsed_ns": elapsed_ns,
        "device": device,
        "device_delta": device_delta,
        "device_read_bytes": device_delta["read_sectors"] * 512,
        "device_read_throughput_bps": device_delta["read_sectors"] * 512 / (elapsed_ns / 1e9),
        "all_device_deltas": deltas,
        "same_filesystem": (
            before["a_path"]["st_dev"] == before["b_path"]["st_dev"] ==
            after["a_path"]["st_dev"] == after["b_path"]["st_dev"]
        ),
        "filesystem_device": f"{before['a_path']['major']}:{before['a_path']['minor']}",
        "cpu_busy_ratio": cpu_busy,
        "cgroup_cpu_busy_ratio": cgroup_busy,
        "cgroup_cpu_capacity_cores": cgroup_capacity,
        "mem_available_bytes": after["memory"].get("MemAvailable", 0),
        "free_bytes": after["b_path"]["free_bytes"],
    }
    pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


parser = argparse.ArgumentParser()
sub = parser.add_subparsers(dest="mode", required=True)
snap = sub.add_parser("snapshot")
snap.add_argument("output")
snap.add_argument("a_path")
snap.add_argument("b_path")
summ = sub.add_parser("summarize")
summ.add_argument("before")
summ.add_argument("after")
summ.add_argument("elapsed_ns")
summ.add_argument("output")
summ.add_argument("--device", default="")
args = parser.parse_args()
if args.mode == "snapshot":
    snapshot(args)
else:
    summarize(args)
