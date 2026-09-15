#!/usr/bin/env python3
import argparse
import json
import pathlib
import time


def cpu_rows():
    rows = {}
    for line in pathlib.Path("/proc/stat").read_text().splitlines():
        fields = line.split()
        if not fields or not fields[0].startswith("cpu") or fields[0] == "cpu" or not fields[0][3:].isdigit():
            continue
        names = ["user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal", "guest", "guest_nice"]
        rows[fields[0][3:]] = {name: int(value) for name, value in zip(names, fields[1:])}
    return rows


def key_values(path):
    result = {}
    try:
        for line in pathlib.Path(path).read_text().splitlines():
            fields = line.split()
            if len(fields) == 2:
                result[fields[0]] = int(fields[1])
    except OSError:
        pass
    return result


def pressure_total(path):
    try:
        return int(pathlib.Path(path).read_text().splitlines()[0].rsplit("total=", 1)[1])
    except Exception:
        return 0


parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("--a-pid", type=int, required=True)
parser.add_argument("--phase", required=True)
args = parser.parse_args()
proc_stat = pathlib.Path(f"/proc/{args.a_pid}/stat").read_text().split()
payload = {
    "schema": "narrow-lane-system-snapshot-v1", "phase": args.phase,
    "captured_at": time.time(), "per_cpu": cpu_rows(),
    "cpu_max": pathlib.Path("/sys/fs/cgroup/cpu.max").read_text().strip() if pathlib.Path("/sys/fs/cgroup/cpu.max").exists() else "max 100000",
    "cpu_stat": key_values("/sys/fs/cgroup/cpu.stat"),
    "cpu_pressure_some_total": pressure_total("/sys/fs/cgroup/cpu.pressure"),
    "a_cpu_ticks": int(proc_stat[13]) + int(proc_stat[14]),
    "a_blkio_ticks": int(proc_stat[41]) if len(proc_stat) > 41 else 0,
}
pathlib.Path(args.output).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
