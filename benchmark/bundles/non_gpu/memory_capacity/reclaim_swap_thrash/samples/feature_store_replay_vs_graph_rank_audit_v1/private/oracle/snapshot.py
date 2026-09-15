#!/usr/bin/env python3
import argparse
import json
import pathlib
import time


def flat(path):
    result = {}
    for line in path.read_text().splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1].lstrip("-").isdigit():
            result[fields[0]] = int(fields[1])
    return result


def pressure(path):
    result = {}
    for line in path.read_text().splitlines():
        fields = line.split()
        values = {}
        for item in fields[1:]:
            key, value = item.split("=", 1)
            values[key] = int(value) if key == "total" else float(value)
        result[fields[0]] = values
    return result


def io_stat(path):
    total = {}
    for line in path.read_text().splitlines():
        for item in line.split()[1:]:
            key, value = item.split("=", 1)
            total[key] = total.get(key, 0) + int(value)
    return total


parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("--pins", required=True)
args = parser.parse_args()
relative = next(line.split(":", 2)[2] for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines() if line.startswith("0:"))
cgroup = pathlib.Path("/sys/fs/cgroup") / relative.lstrip("/")
pins = json.loads(pathlib.Path(args.pins).read_text())


def read(name):
    return (cgroup / name).read_text().strip()


lock_lines = pathlib.Path("/proc/locks").read_text().splitlines()
input_locks = [line for line in lock_lines if line.rsplit(":", 1)[-1].split()[0] in {str(pins["a_inode"]), str(pins["b_inode"])}]
payload = {
    "wall_time": time.time(),
    "monotonic": time.monotonic(),
    "pins": pins,
    "input_locks": input_locks,
    "memory_current": int(read("memory.current")),
    "memory_max": read("memory.max"),
    "memory_high": read("memory.high"),
    "memory_swap_current": int(read("memory.swap.current")),
    "memory_swap_max": read("memory.swap.max"),
    "memory_stat": flat(cgroup / "memory.stat"),
    "memory_events": flat(cgroup / "memory.events"),
    "memory_pressure": pressure(cgroup / "memory.pressure"),
    "cpu_max": read("cpu.max"),
    "cpuset": read("cpuset.cpus.effective"),
    "cpu_stat": flat(cgroup / "cpu.stat"),
    "cpu_pressure": pressure(cgroup / "cpu.pressure"),
    "io_stat": io_stat(cgroup / "io.stat"),
    "io_pressure": pressure(cgroup / "io.pressure"),
}
pathlib.Path(args.output).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
