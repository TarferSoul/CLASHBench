#!/usr/bin/env python3
"""Sample CPU topology confounders during a bounded throughput trial."""

import argparse
import json
import os
import pathlib
import time


def parse_env(path):
    return dict(
        line.split("=", 1)
        for line in pathlib.Path(path).read_text().splitlines()
        if line and not line.startswith("#")
    )


def key_values(path):
    result = {}
    for line in pathlib.Path(path).read_text().splitlines():
        fields = line.split()
        if len(fields) == 2:
            try:
                result[fields[0]] = int(fields[1])
            except ValueError:
                pass
    return result


def pressure(path):
    result = {}
    for line in pathlib.Path(path).read_text().splitlines():
        fields = line.split()
        if not fields:
            continue
        for field in fields[1:]:
            key, separator, value = field.partition("=")
            if separator and key == "total":
                result[fields[0]] = int(value)
    return result


def cpu_times(cpus):
    wanted = {f"cpu{cpu}": cpu for cpu in cpus}
    result = {}
    for line in pathlib.Path("/proc/stat").read_text().splitlines():
        fields = line.split()
        if not fields or fields[0] not in wanted:
            continue
        result[str(wanted[fields[0]])] = [int(item) for item in fields[1:]]
    return result


def proc_cpuinfo_frequencies():
    result = {}
    current = None
    for line in pathlib.Path("/proc/cpuinfo").read_text(errors="replace").splitlines():
        if not line:
            current = None
            continue
        key, separator, value = line.partition(":")
        if not separator:
            continue
        key = key.strip()
        value = value.strip()
        if key == "processor":
            current = int(value)
        elif key == "cpu MHz" and current is not None:
            result[current] = float(value) * 1000.0
    return result


def frequencies(mode, cpus):
    if mode in {"scaling_cur_freq", "cpuinfo_cur_freq"}:
        result = {}
        for cpu in cpus:
            path = pathlib.Path(
                f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/{mode}"
            )
            try:
                result[str(cpu)] = float(path.read_text().strip())
            except (FileNotFoundError, PermissionError, ValueError):
                result[str(cpu)] = None
        return result
    values = proc_cpuinfo_frequencies()
    return {str(cpu): values.get(cpu) for cpu in cpus}


def numeric_files(value):
    result = {}
    for name in filter(None, value.split(",")):
        path = pathlib.Path(name)
        try:
            result[name] = int(path.read_text().strip())
        except (FileNotFoundError, PermissionError, ValueError):
            result[name] = None
    return result


def cgroup_dir():
    rel = next(
        line.split(":", 2)[2]
        for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines()
        if line.startswith("0:")
    )
    return pathlib.Path("/sys/fs/cgroup") / rel.lstrip("/")


def sample(topology, cg, cpus):
    memory_max_text = (cg / "memory.max").read_text().strip()
    return {
        "monotonic": time.monotonic(),
        "wall_time": time.time(),
        "cpu_times": cpu_times(cpus),
        "frequency_khz": frequencies(topology["FREQUENCY_MODE"], cpus),
        "temperature_millic": numeric_files(topology.get("THERMAL_PATHS", "")),
        "thermal_throttle_counts": numeric_files(topology.get("THROTTLE_PATHS", "")),
        "cpu_stat": key_values(cg / "cpu.stat"),
        "cpu_pressure": pressure(cg / "cpu.pressure"),
        "io_pressure": pressure(cg / "io.pressure"),
        "memory_current": int((cg / "memory.current").read_text()),
        "memory_max": None if memory_max_text == "max" else int(memory_max_text),
        "memory_events": key_values(cg / "memory.events"),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--topology", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--stop-file", required=True)
    parser.add_argument("--interval", type=float, default=0.1)
    args = parser.parse_args()
    topology = parse_env(args.topology)
    cpus = [int(topology["A_CPU"]), int(topology["B_CPU"])]
    output = pathlib.Path(args.output)
    stop_file = pathlib.Path(args.stop_file)
    output.parent.mkdir(parents=True, exist_ok=True)
    cg = cgroup_dir()
    with output.open("w", encoding="utf-8") as handle:
        while True:
            handle.write(json.dumps(sample(topology, cg, cpus), sort_keys=True) + "\n")
            handle.flush()
            if stop_file.exists():
                break
            time.sleep(args.interval)


if __name__ == "__main__":
    main()
